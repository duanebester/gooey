//! Image Component
//!
//! Renders an image from a file path or embedded asset. Handles loading,
//! caching, and GPU upload automatically - just pass the source and style.
//!
//! ## Usage
//! ```zig
//! const gooey = @import("gooey");
//!
//! // Simple image from path
//! gooey.Image{ .src = "assets/logo.png" }
//!
//! // With explicit sizing
//! gooey.Image{ .src = "photo.jpg", .width = 200, .height = 150 }
//!
//! // Rounded avatar
//! gooey.Image{ .src = "avatar.png", .size = 48, .rounded = true }
//!
//! // Cover image (fills container, may crop)
//! gooey.Image{ .src = "banner.jpg", .width = 800, .height = 200, .fit = .cover }
//!
//! // Grayscale + tinted
//! gooey.Image{ .src = "icon.png", .grayscale = 1.0, .tint = gooey.Color.blue }
//! ```

const std = @import("std");
const ui = @import("../ui/ui.zig");
const Color = ui.Color;
const CornerRadius = @import("../layout/layout.zig").CornerRadius;

pub const Image = struct {
    /// Image source - file path or embedded asset path
    src: []const u8,

    /// Uniform size (sets both width and height). Ignored if width/height set.
    size: ?f32 = null,

    /// Explicit width (overrides size)
    width: ?f32 = null,

    /// Explicit height (overrides size)
    height: ?f32 = null,

    /// Object fit mode - how the image should fit within its container
    fit: ui.ObjectFit = .contain,

    /// Corner radius (single value for all corners)
    corner_radius: ?f32 = null,

    /// Make fully rounded (circular for square images)
    rounded: bool = false,

    /// Tint color overlay (multiplied with image colors)
    tint: ?Color = null,

    /// Grayscale filter (0.0 = full color, 1.0 = grayscale)
    grayscale: f32 = 0,

    /// Opacity (0.0 = transparent, 1.0 = opaque)
    opacity: f32 = 1,

    /// Alt text for accessibility (future use)
    alt: ?[]const u8 = null,

    /// Render the image component
    pub fn render(self: Image, b: *ui.Builder) void {
        // Determine final dimensions
        const w = self.width orelse self.size;
        const h = self.height orelse self.size;

        // Calculate corner radius value
        const radius_value: f32 = if (self.rounded) blk: {
            // For rounded, use half the smaller dimension (or infinity if size unknown - will be clamped by renderer)
            break :blk if (w) |width| width / 2 else if (h) |height| height / 2 else std.math.inf(f32);
        } else if (self.corner_radius) |r| r else 0;

        // Create CornerRadius struct for ImagePrimitive (which needs per-corner values)
        const corner_radius_struct: ?CornerRadius = if (radius_value > 0)
            CornerRadius.all(radius_value)
        else
            null;

        // Emit the image primitive
        b.box(.{
            .width = w,
            .height = h,
            .corner_radius = radius_value,
        }, .{
            ui.ImagePrimitive{
                .source = self.src,
                .width = w,
                .height = h,
                .fit = self.fit,
                .corner_radius = corner_radius_struct,
                .tint = self.tint,
                .grayscale = self.grayscale,
                .opacity = self.opacity,
            },
        });
    }
};

/// Aspect ratio helper for common image dimensions
pub const AspectRatio = struct {
    pub const square = struct { width: f32 = 1, height: f32 = 1 };
    pub const landscape_4_3 = struct { width: f32 = 4, height: f32 = 3 };
    pub const landscape_16_9 = struct { width: f32 = 16, height: f32 = 9 };
    pub const portrait_3_4 = struct { width: f32 = 3, height: f32 = 4 };
    pub const portrait_9_16 = struct { width: f32 = 9, height: f32 = 16 };

    /// Calculate height from width and aspect ratio
    pub fn heightFromWidth(width: f32, ratio_width: f32, ratio_height: f32) f32 {
        return width * ratio_height / ratio_width;
    }

    /// Calculate width from height and aspect ratio
    pub fn widthFromHeight(height: f32, ratio_width: f32, ratio_height: f32) f32 {
        return height * ratio_width / ratio_height;
    }
};
