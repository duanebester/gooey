struct Params {
    float4 start;
    float4 end;
    float2 direction;
    uint interpolation;
    uint _pad;
};

constant uint interpolation_oklab = 1;

float3 srgb_decode(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

float3 srgb_encode(float3 c) {
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
}

float3 signed_cbrt(float3 x) {
    return copysign(pow(abs(x), 1.0 / 3.0), x);
}

float3 oklab_from_linear(float3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float3 lms = signed_cbrt(float3(l, m, s));
    return float3(
        0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
        1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
        0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z);
}

float3 linear_from_oklab(float3 lab) {
    float3 lms = float3(
        lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
        lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
        lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
    lms = lms * lms * lms;
    return float3(
        4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
        -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
        -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z);
}

float4 mix_premultiplied(float4 start, float4 end, float t) {
    float alpha = mix(start.a, end.a, t);
    float3 color = mix(start.rgb, end.rgb, t * end.a / alpha);
    return float4(alpha > 0.0 ? color : float3(0.0), alpha);
}

float4 mix_oklab(float4 start, float4 end, float t) {
    float4 lab = mix_premultiplied(float4(oklab_from_linear(srgb_decode(start.rgb)), start.a),
                                   float4(oklab_from_linear(srgb_decode(end.rgb)), end.a), t);
    float3 rgb = srgb_encode(clamp(linear_from_oklab(lab.rgb), 0.0, 1.0));
    return float4(rgb, lab.a);
}

float4 shade(ShadeInput in, constant Params& p) {
    float2 centered = (in.uv - 0.5) * in.size;
    float half_length = 0.5 * (abs(in.size.x * p.direction.x) + abs(in.size.y * p.direction.y));
    float t = clamp(dot(centered, p.direction) / max(2.0 * half_length, 1e-6) + 0.5, 0.0, 1.0);
    if (p.interpolation == interpolation_oklab) return mix_oklab(p.start, p.end, t);
    return mix_premultiplied(p.start, p.end, t);
}
