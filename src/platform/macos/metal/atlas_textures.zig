const std = @import("std");
const assert = std.debug.assert;

const objc = @import("objc");
const mtl = @import("api.zig");
const limits_mod = @import("../../../core/limits.zig");
const backend = @import("../../../core/backend.zig");

pub const AtlasTextures = struct {
    glyph: objc.Object,
    svg: objc.Object,
    image: objc.Object,
    limits: limits_mod.AtlasLimits,

    const Self = @This();

    pub fn init(device: objc.Object, limits: *const limits_mod.AtlasLimits) !Self {
        assert(limits.text_size > 0);
        assert(limits.image_size > 0);
        const glyph = try createTexture(device, limits.text_size, .r8unorm);
        errdefer glyph.release();
        const svg = try createTexture(device, limits.svg_size, .rgba8unorm);
        errdefer svg.release();
        const image = try createTexture(device, limits.image_size, .rgba8unorm);
        return .{ .glyph = glyph, .svg = svg, .image = image, .limits = limits.* };
    }

    pub fn deinit(self: *Self) void {
        assert(self.glyph.value != null);
        self.image.release();
        self.svg.release();
        self.glyph.release();
        self.* = undefined;
    }

    pub fn bytesPerPixel(kind: backend.AtlasKind) u32 {
        return switch (kind) {
            .glyph => 1,
            .svg, .image => 4,
            .glyph_color => unsupported(kind),
        };
    }

    pub fn encodeCopy(
        self: *const Self,
        blit: objc.Object,
        staging: objc.Object,
        upload: struct { kind: backend.AtlasKind, dirty: backend.RectPx, offset: u32 },
    ) void {
        const texture, const size = switch (upload.kind) {
            .glyph => .{ self.glyph, self.limits.text_size },
            .svg => .{ self.svg, self.limits.svg_size },
            .image => .{ self.image, self.limits.image_size },
            .glyph_color => unsupported(upload.kind),
        };
        const dirty = upload.dirty;
        assert(dirty.x <= size);
        assert(dirty.width <= size - dirty.x);
        assert(dirty.y <= size);
        assert(dirty.height <= size - dirty.y);
        const bytes_per_pixel = bytesPerPixel(upload.kind);
        assert(upload.offset % bytes_per_pixel == 0);
        const row_bytes = @as(c_ulong, dirty.width) * bytes_per_pixel;
        blit.msgSend(void, "copyFromBuffer:sourceOffset:sourceBytesPerRow:" ++
            "sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:" ++
            "destinationOrigin:", .{
            staging.value,
            @as(c_ulong, upload.offset),
            row_bytes,
            row_bytes * dirty.height,
            mtl.MTLSize{ .width = dirty.width, .height = dirty.height, .depth = 1 },
            texture.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
            mtl.MTLOrigin{ .x = dirty.x, .y = dirty.y, .z = 0 },
        });
    }
};

fn unsupported(kind: backend.AtlasKind) noreturn {
    std.debug.panic("Metal has no {t} atlas texture; nothing uploads it yet.", .{kind});
}

fn createTexture(device: objc.Object, size: u32, format: mtl.MTLPixelFormat) !objc.Object {
    assert(size > 0);
    assert(format == .r8unorm or format == .rgba8unorm);
    const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse
        return error.ClassNotFound;
    const descriptor = MTLTextureDescriptor.msgSend(
        objc.Object,
        "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        .{ @backingInt(format), @as(c_ulong, size), @as(c_ulong, size), false },
    );
    const usage = mtl.MTLTextureUsage.shader_read_only;
    descriptor.msgSend(void, "setUsage:", .{@as(c_ulong, @bitCast(usage))});
    descriptor.msgSend(void, "setStorageMode:", .{@backingInt(mtl.MTLStorageMode.private)});
    const tracked = mtl.MTLResourceOptions.HazardTrackingMode.tracked;
    descriptor.msgSend(void, "setHazardTrackingMode:", .{@as(c_ulong, @backingInt(tracked))});
    const texture_ptr = device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{
        descriptor.value,
    }) orelse return error.TextureCreationFailed;
    const texture = objc.Object.fromId(texture_ptr);
    assert(texture.msgSend(c_ulong, "width", .{}) == size);
    assert(texture.msgSend(c_ulong, "hazardTrackingMode", .{}) == @backingInt(tracked));
    return texture;
}
