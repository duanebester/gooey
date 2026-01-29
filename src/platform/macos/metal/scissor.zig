//! Scissor Utilities - Clipping region support for Metal rendering
//!
//! Provides helpers for converting layout bounds to Metal scissor rectangles.

const objc = @import("objc");

/// Scissor rectangle in pixels
pub const ScissorRect = extern struct {
    x: c_ulong,
    y: c_ulong,
    width: c_ulong,
    height: c_ulong,
};

/// Set scissor rectangle on encoder for clipping
pub fn setScissor(encoder: objc.Object, rect: ScissorRect) void {
    encoder.msgSend(void, "setScissorRect:", .{rect});
}

/// Convert layout bounding box to scissor rect
/// Accounts for Retina scale factor and Metal's bottom-left origin
pub fn boundsToScissorRect(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    viewport_height: f32,
    scale: f64,
) ScissorRect {
    // Metal scissor Y is from bottom, but our layout Y is from top
    const scale_f: f32 = @floatCast(scale);
    const flipped_y = viewport_height - y - height;

    return .{
        .x = @intFromFloat(@max(0, x * scale_f)),
        .y = @intFromFloat(@max(0, flipped_y * scale_f)),
        .width = @intFromFloat(@max(1, width * scale_f)),
        .height = @intFromFloat(@max(1, height * scale_f)),
    };
}

/// Reset scissor to full viewport
pub fn resetScissor(encoder: objc.Object, width: f64, height: f64, scale_factor: f64) void {
    const rect = ScissorRect{
        .x = 0,
        .y = 0,
        .width = @intFromFloat(width * scale_factor),
        .height = @intFromFloat(height * scale_factor),
    };
    encoder.msgSend(void, "setScissorRect:", .{rect});
}

/// Helper to set scissor from layout bounds
pub fn setScissorFromBounds(
    encoder: objc.Object,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    viewport_height: f32,
    scale_factor: f64,
) void {
    const rect = boundsToScissorRect(x, y, width, height, viewport_height, scale_factor);
    setScissor(encoder, rect);
}
