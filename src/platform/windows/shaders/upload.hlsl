
StructuredBuffer<uint> upload_words : register(t0);

struct UploadVaryings {
    float4 position : SV_Position;
    nointerpolation uint record : RECORD;
};

static const uint kind_glyph = 0;
static const uint kind_svg = 1;
static const uint kind_image = 2;

float2 upload_corner(uint vid) {
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

UploadVaryings upload_vertex(uint vid, uint record, uint kind) {
    uint word_x_y = upload_words[record * 4 + 1];
    uint word_size = upload_words[record * 4 + 2];
    uint word_atlas = upload_words[record * 4 + 3];
    float2 origin = float2(word_x_y & 0xFFFF, word_x_y >> 16);
    float2 size = float2(word_size & 0xFFFF, word_size >> 16);
    float side = (float)(word_atlas & 0xFFFF);
    if ((word_atlas >> 16) != kind) {
        size = float2(0.0, 0.0);
    }
    float2 pixel = origin + upload_corner(vid) * size;
    float2 ndc = pixel / side * 2.0 - 1.0;
    UploadVaryings o;
    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.record = record;
    return o;
}

UploadVaryings vs_glyph(uint vid : SV_VertexID, uint record : INSTANCE_INDEX) {
    return upload_vertex(vid, record, kind_glyph);
}

UploadVaryings vs_svg(uint vid : SV_VertexID, uint record : INSTANCE_INDEX) {
    return upload_vertex(vid, record, kind_svg);
}

UploadVaryings vs_image(uint vid : SV_VertexID, uint record : INSTANCE_INDEX) {
    return upload_vertex(vid, record, kind_image);
}

uint upload_address(UploadVaryings i, uint bytes_per_pixel) {
    uint word_x_y = upload_words[i.record * 4 + 1];
    uint width = upload_words[i.record * 4 + 2] & 0xFFFF;
    uint2 local = uint2(i.position.xy) - uint2(word_x_y & 0xFFFF, word_x_y >> 16);
    return upload_words[i.record * 4] + (local.y * width + local.x) * bytes_per_pixel;
}

float4 ps_r8(UploadVaryings i) : SV_Target {
    uint address = upload_address(i, 1);
    uint word = upload_words[address >> 2];
    float coverage = (float)((word >> ((address & 3) * 8)) & 0xFF) / 255.0;
    return float4(coverage, 0.0, 0.0, 0.0);
}

float4 ps_rgba8(UploadVaryings i) : SV_Target {
    uint word = upload_words[upload_address(i, 4) >> 2];
    return float4(word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF, word >> 24) / 255.0;
}
