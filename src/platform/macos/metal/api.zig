//! Metal API type definitions for gooey
//!
//! Clean Zig types instead of @cImport magic numbers.
//! Inspired by Ghostty's approach - see https://github.com/ghostty-org/ghostty
//!
//! Reference: https://developer.apple.com/metal/cpp/

const std = @import("std");

// ============================================================================
// Enums
// ============================================================================

/// https://developer.apple.com/documentation/metal/mtlloadaction
pub const MTLLoadAction = enum(c_ulong) {
    dont_care = 0,
    load = 1,
    clear = 2,
};

/// https://developer.apple.com/documentation/metal/mtlstoreaction
pub const MTLStoreAction = enum(c_ulong) {
    dont_care = 0,
    store = 1,
    multisample_resolve = 2,
    store_and_multisample_resolve = 3,
    unknown = 4,
    custom_sample_depth_store = 5,
};

/// https://developer.apple.com/documentation/metal/mtlprimitivetype
pub const MTLPrimitiveType = enum(c_ulong) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

/// https://developer.apple.com/documentation/metal/mtlindextype
pub const MTLIndexType = enum(c_ulong) {
    uint16 = 0,
    uint32 = 1,
};

/// https://developer.apple.com/documentation/metal/mtlvertexformat
pub const MTLVertexFormat = enum(c_ulong) {
    invalid = 0,
    uchar2 = 1,
    uchar3 = 2,
    uchar4 = 3,
    char2 = 4,
    char3 = 5,
    char4 = 6,
    uchar2normalized = 7,
    uchar3normalized = 8,
    uchar4normalized = 9,
    char2normalized = 10,
    char3normalized = 11,
    char4normalized = 12,
    ushort2 = 13,
    ushort3 = 14,
    ushort4 = 15,
    short2 = 16,
    short3 = 17,
    short4 = 18,
    ushort2normalized = 19,
    ushort3normalized = 20,
    ushort4normalized = 21,
    short2normalized = 22,
    short3normalized = 23,
    short4normalized = 24,
    half2 = 25,
    half3 = 26,
    half4 = 27,
    float = 28,
    float2 = 29,
    float3 = 30,
    float4 = 31,
    int = 32,
    int2 = 33,
    int3 = 34,
    int4 = 35,
    uint = 36,
    uint2 = 37,
    uint3 = 38,
    uint4 = 39,
};

/// https://developer.apple.com/documentation/metal/mtlvertexstepfunction
pub const MTLVertexStepFunction = enum(c_ulong) {
    constant = 0,
    per_vertex = 1,
    per_instance = 2,
    per_patch = 3,
    per_patch_control_point = 4,
};

/// https://developer.apple.com/documentation/metal/mtlpixelformat
pub const MTLPixelFormat = enum(c_ulong) {
    invalid = 0,
    a8unorm = 1,
    r8unorm = 10,
    r8unorm_srgb = 11,
    r8snorm = 12,
    r8uint = 13,
    r8sint = 14,
    r16unorm = 20,
    r16snorm = 22,
    r16uint = 23,
    r16sint = 24,
    r16float = 25,
    rg8unorm = 30,
    rg8unorm_srgb = 31,
    rg8snorm = 32,
    rg8uint = 33,
    rg8sint = 34,
    r32uint = 53,
    r32sint = 54,
    r32float = 55,
    rg16unorm = 60,
    rg16snorm = 62,
    rg16uint = 63,
    rg16sint = 64,
    rg16float = 65,
    rgba8unorm = 70,
    rgba8unorm_srgb = 71,
    rgba8snorm = 72,
    rgba8uint = 73,
    rgba8sint = 74,
    bgra8unorm = 80,
    bgra8unorm_srgb = 81,
    rgb10a2unorm = 90,
    rgb10a2uint = 91,
    rg11b10float = 92,
    rgb9e5float = 93,
    rg32uint = 103,
    rg32sint = 104,
    rg32float = 105,
    rgba16unorm = 110,
    rgba16snorm = 112,
    rgba16uint = 113,
    rgba16sint = 114,
    rgba16float = 115,
    rgba32uint = 123,
    rgba32sint = 124,
    rgba32float = 125,
    depth16unorm = 250,
    depth32float = 252,
    stencil8 = 253,
    depth24unorm_stencil8 = 255,
    depth32float_stencil8 = 260,
};

/// https://developer.apple.com/documentation/metal/mtltexturetype
pub const MTLTextureType = enum(c_ulong) {
    type_1d = 0,
    type_1d_array = 1,
    type_2d = 2,
    type_2d_array = 3,
    type_2d_multisample = 4,
    type_cube = 5,
    type_cube_array = 6,
    type_3d = 7,
};

/// https://developer.apple.com/documentation/metal/mtltextureusage
pub const MTLTextureUsage = packed struct(c_ulong) {
    shader_read: bool = false,
    shader_write: bool = false,
    render_target: bool = false,
    _reserved: u1 = 0,
    pixel_format_view: bool = false,
    shader_atomic: bool = false,
    _pad: @Type(.{ .int = .{ .signedness = .unsigned, .bits = @bitSizeOf(c_ulong) - 6 } }) = 0,

    pub const unknown: MTLTextureUsage = @bitCast(@as(c_ulong, 0));
    pub const render_target_only: MTLTextureUsage = .{ .render_target = true };
    pub const shader_read_only: MTLTextureUsage = .{ .shader_read = true };
};

/// https://developer.apple.com/documentation/metal/mtlresourceoptions
pub const MTLResourceOptions = packed struct(c_ulong) {
    cpu_cache_mode: CPUCacheMode = .default,
    storage_mode: StorageMode = .shared,
    hazard_tracking_mode: HazardTrackingMode = .default,
    _pad: @Type(.{ .int = .{ .signedness = .unsigned, .bits = @bitSizeOf(c_ulong) - 10 } }) = 0,

    pub const CPUCacheMode = enum(u4) {
        default = 0,
        write_combined = 1,
    };

    pub const StorageMode = enum(u4) {
        shared = 0,
        managed = 1,
        private = 2,
        memoryless = 3,
    };

    pub const HazardTrackingMode = enum(u2) {
        default = 0,
        untracked = 1,
        tracked = 2,
    };

    /// Convenience: default shared storage
    pub const storage_shared: MTLResourceOptions = .{ .storage_mode = .shared };
    /// Convenience: private GPU-only storage
    pub const storage_private: MTLResourceOptions = .{ .storage_mode = .private };
};

/// https://developer.apple.com/documentation/metal/mtlblendfactor
pub const MTLBlendFactor = enum(c_ulong) {
    zero = 0,
    one = 1,
    source_color = 2,
    one_minus_source_color = 3,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    dest_color = 6,
    one_minus_dest_color = 7,
    dest_alpha = 8,
    one_minus_dest_alpha = 9,
    source_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
};

/// https://developer.apple.com/documentation/metal/mtlblendoperation
pub const MTLBlendOperation = enum(c_ulong) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

// ============================================================================
// Structs
// ============================================================================

pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,

    pub fn init(r: f64, g: f64, b: f64, a: f64) MTLClearColor {
        return .{ .red = r, .green = g, .blue = b, .alpha = a };
    }

    pub fn fromColor(color: anytype) MTLClearColor {
        return .{
            .red = @floatCast(color.r),
            .green = @floatCast(color.g),
            .blue = @floatCast(color.b),
            .alpha = @floatCast(color.a),
        };
    }
};

pub const MTLViewport = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

pub const MTLOrigin = extern struct {
    x: c_ulong,
    y: c_ulong,
    z: c_ulong,
};

pub const MTLSize = extern struct {
    width: c_ulong,
    height: c_ulong,
    depth: c_ulong,
};

pub const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

/// https://developer.apple.com/documentation/metal/mtlstoragemode
pub const MTLStorageMode = enum(c_ulong) {
    shared = 0, // CPU + GPU (unified memory)
    managed = 1, // CPU + GPU with sync (discrete GPUs)
    private = 2, // GPU only
    memoryless = 3, // Tile memory only (Apple GPUs, render targets)
};

/// CoreGraphics size - used by CAMetalLayer
pub const CGSize = extern struct {
    width: f64,
    height: f64,
};

// ============================================================================
// External Functions
// ============================================================================

/// https://developer.apple.com/documentation/metal/1433401-mtlcreatesystemdefaultdevice
pub extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

/// https://developer.apple.com/documentation/metal/1433367-mtlcopyalldevices
pub extern "c" fn MTLCopyAllDevices() ?*anyopaque;
