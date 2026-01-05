//! ImageInstance - GPU-ready data for rendering atlas-cached images
//!
//! Similar to GlyphInstance/SvgInstance but for raster images.
//! Supports tinting, opacity, grayscale, and rounded corners.

const std = @import("std");
const scene = @import("scene.zig");

pub const ImageInstance = extern struct {
    // Draw order for z-index interleaving
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0, // Maintain 8-byte alignment

    // Screen position (top-left, logical pixels)
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    // Destination size (logical pixels)
    dest_width: f32 = 0,
    dest_height: f32 = 0,

    // Atlas UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 1,
    uv_bottom: f32 = 1,

    // Padding to align tint (float4) to 16-byte boundary
    // Without this, tint would be at offset 40; Metal requires float4 at 16-byte aligned offset (48)
    _pad1: u32 = 0,
    _pad2: u32 = 0,

    // Tint color (HSLA) - multiplied with image, must be at 16-byte aligned offset for Metal float4
    tint: scene.Hsla = scene.Hsla.white,

    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    // Corner radii for rounded images
    corner_tl: f32 = 0,
    corner_tr: f32 = 0,
    corner_br: f32 = 0,
    corner_bl: f32 = 0,

    // Visual effects
    grayscale: f32 = 0, // 0.0 = color, 1.0 = grayscale
    opacity: f32 = 1, // 0.0 = transparent, 1.0 = opaque

    // Padding for 16-byte struct alignment
    _pad3: f32 = 0,
    _pad4: f32 = 0,

    pub fn init(
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        uv_left_arg: f32,
        uv_top_arg: f32,
        uv_right_arg: f32,
        uv_bottom_arg: f32,
    ) ImageInstance {
        // Assert valid size: dimensions must be non-negative
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        // Assert valid UV coordinates: must be in normalized range [0, 1]
        std.debug.assert(uv_left_arg >= 0 and uv_left_arg <= 1);
        std.debug.assert(uv_top_arg >= 0 and uv_top_arg <= 1);
        std.debug.assert(uv_right_arg >= 0 and uv_right_arg <= 1);
        std.debug.assert(uv_bottom_arg >= 0 and uv_bottom_arg <= 1);
        return .{
            .pos_x = x,
            .pos_y = y,
            .dest_width = width,
            .dest_height = height,
            .uv_left = uv_left_arg,
            .uv_top = uv_top_arg,
            .uv_right = uv_right_arg,
            .uv_bottom = uv_bottom_arg,
        };
    }

    pub fn withTint(self: ImageInstance, tint_color: scene.Hsla) ImageInstance {
        var img = self;
        img.tint = tint_color;
        return img;
    }

    pub fn withOpacity(self: ImageInstance, alpha: f32) ImageInstance {
        // Assert valid opacity: must be in range [0, 1]
        std.debug.assert(alpha >= 0 and alpha <= 1);
        var img = self;
        img.opacity = alpha;
        return img;
    }

    pub fn withGrayscale(self: ImageInstance, amount: f32) ImageInstance {
        // Assert valid grayscale: must be in range [0, 1]
        std.debug.assert(amount >= 0 and amount <= 1);
        var img = self;
        img.grayscale = amount;
        return img;
    }

    pub fn withCornerRadius(self: ImageInstance, radius: f32) ImageInstance {
        // Assert valid corner radius
        std.debug.assert(radius >= 0);
        var img = self;
        img.corner_tl = radius;
        img.corner_tr = radius;
        img.corner_br = radius;
        img.corner_bl = radius;
        return img;
    }

    pub fn withCornerRadii(
        self: ImageInstance,
        tl: f32,
        tr: f32,
        br: f32,
        bl: f32,
    ) ImageInstance {
        // Assert valid corner radii
        std.debug.assert(tl >= 0);
        std.debug.assert(tr >= 0);
        std.debug.assert(br >= 0);
        std.debug.assert(bl >= 0);
        var img = self;
        img.corner_tl = tl;
        img.corner_tr = tr;
        img.corner_br = br;
        img.corner_bl = bl;
        return img;
    }

    pub fn withClipBounds(self: ImageInstance, clip: scene.ContentMask.ClipBounds) ImageInstance {
        var img = self;
        img.clip_x = clip.x;
        img.clip_y = clip.y;
        img.clip_width = clip.width;
        img.clip_height = clip.height;
        return img;
    }

    pub fn withClip(self: ImageInstance, x: f32, y: f32, w: f32, h: f32) ImageInstance {
        var img = self;
        img.clip_x = x;
        img.clip_y = y;
        img.clip_width = w;
        img.clip_height = h;
        return img;
    }
};

// Compile-time verification of struct layout for Metal compatibility
comptime {
    // Struct must be 112 bytes for proper GPU buffer alignment
    if (@sizeOf(ImageInstance) != 112) {
        @compileError(std.fmt.comptimePrint(
            "ImageInstance must be 112 bytes, got {}",
            .{@sizeOf(ImageInstance)},
        ));
    }
    // Verify tint is at 16-byte aligned offset for Metal float4
    if (@offsetOf(ImageInstance, "tint") != 48) {
        @compileError(std.fmt.comptimePrint(
            "ImageInstance.tint must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(ImageInstance, "tint")},
        ));
    }
}
