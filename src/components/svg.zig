//! SVG Component
//!
//! Renders an SVG icon from path data. Handles mesh tessellation and GPU
//! upload automatically - just pass the path data and style.
//!
//! ## Usage
//! ```zig
//! const star_path = "M12 2l3.09 6.26L22 9.27l-5 4.87...";
//!
//! // Simple filled icon
//! gooey.Svg{ .path = star_path, .size = 24, .color = .gold }
//!
//! // Stroked icon (outline only)
//! gooey.Svg{ .path = star_path, .size = 24, .stroke_color = .white, .stroke_width = 2 }
//!
//! // Both fill and stroke
//! gooey.Svg{ .path = star_path, .size = 24, .color = .red, .stroke_color = .black, .stroke_width = 1 }
//! ```

const std = @import("std");
const ui = @import("../ui/mod.zig");
const Color = ui.Color;

pub const Svg = struct {
    /// SVG path data (the `d` attribute from an SVG path element)
    path: []const u8,

    /// Uniform size (sets both width and height). Ignored if width/height set.
    size: ?f32 = null,

    /// Explicit width (overrides size)
    width: ?f32 = null,

    /// Explicit height (overrides size)
    height: ?f32 = null,

    /// Fill color (null = no fill)
    color: ?Color = Color.black,

    /// Stroke color (null = no stroke)
    stroke_color: ?Color = null,

    /// Stroke width in logical pixels
    stroke_width: f32 = 1.0,

    /// Viewbox size of the source SVG (default 24x24 for Material icons)
    viewbox: f32 = 24,

    pub fn render(self: Svg, b: *ui.Builder) void {
        // Determine final dimensions
        const w = self.width orelse self.size orelse 24;
        const h = self.height orelse self.size orelse 24;

        // Emit the SVG primitive (atlas handles caching internally)
        b.box(.{}, .{
            ui.SvgPrimitive{
                .path = self.path,
                .width = w,
                .height = h,
                .color = self.color orelse Color.transparent,
                .stroke_color = self.stroke_color,
                .stroke_width = self.stroke_width,
                .viewbox = self.viewbox,
                .has_fill = self.color != null,
            },
        });
    }
};

/// Common icon paths (Material Design Icons subset)
pub const Icons = struct {
    // Navigation
    pub const arrow_back = "m12 19-7-7 7-7 M19 12H5";
    pub const arrow_forward = "M12 4l-1.41 1.41L16.17 11H4v2h12.17l-5.58 5.59L12 20l8-8z";
    pub const menu = "M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z";
    pub const close = "M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z";
    pub const more_vert = "M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z";

    // Actions
    pub const check = "M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z";
    pub const add = "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z";
    pub const remove = "M19 13H5v-2h14v2z";
    pub const edit = "M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z";
    pub const delete = "M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z";
    pub const search = "M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z";

    // Status
    pub const star = "M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z";
    pub const star_outline = "M22 9.24l-7.19-.62L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21 12 17.27 18.18 21l-1.63-7.03L22 9.24zM12 15.4l-3.76 2.27 1-4.28-3.32-2.88 4.38-.38L12 6.1l1.71 4.04 4.38.38-3.32 2.88 1 4.28L12 15.4z";
    pub const favorite = "M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z";
    pub const info = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z";
    pub const warning = "M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z";
    pub const error_icon = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z";

    // Media
    pub const play = "M8 5v14l11-7z";
    pub const pause = "M6 19h4V5H6v14zm8-14v14h4V5h-4z";
    pub const skip_next = "M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z";
    pub const skip_prev = "M6 6h2v12H6zm3.5 6l8.5 6V6z";
    pub const volume_up = "M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z";

    // Toggle
    pub const visibility = "M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z";
    pub const visibility_off = "M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z";

    // File
    pub const folder = "M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z";
    pub const file = "M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z";
    pub const download = "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z";
    pub const upload = "M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z";
};
