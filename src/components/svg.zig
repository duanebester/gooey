//! SVG Component
//!
//! Renders an SVG icon from path data. Handles mesh tessellation and GPU
//! upload automatically - just pass the path data and style.
//!
//! ## Fill Behavior
//! - `color = null` (default): Uses theme text color for fill
//! - `color = .some_color`: Uses explicit fill color
//! - `no_fill = true`: Disables fill entirely (for stroke-only icons)
//!
//! ## Usage
//! ```zig
//! const star_path = "M12 2l3.09 6.26L22 9.27l-5 4.87...";
//! const wave_path = "M2 12 Q6 6 12 12 T22 12";
//!
//! // Simple filled icon (uses theme text color)
//! gooey.Svg{ .path = star_path, .size = 24 }
//!
//! // Explicit fill color
//! gooey.Svg{ .path = star_path, .size = 24, .color = .gold }
//!
//! // Stroke-only icon (no fill) - use no_fill = true for open paths like curves
//! gooey.Svg{ .path = wave_path, .size = 24, .no_fill = true, .stroke_color = .white, .stroke_width = 2 }
//!
//! // Both fill and stroke
//! gooey.Svg{ .path = star_path, .size = 24, .color = .red, .stroke_color = .black, .stroke_width = 1 }
//! ```

const std = @import("std");
const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

pub const Svg = struct {
    /// SVG path data (the `d` attribute from an SVG path element)
    path: []const u8,

    /// Uniform size (sets both width and height). Ignored if width/height set.
    size: ?f32 = null,

    /// Explicit width (overrides size)
    width: ?f32 = null,

    /// Explicit height (overrides size)
    height: ?f32 = null,

    /// Fill color (null = use theme text color, explicit null via .no_fill = true means no fill)
    color: ?Color = null,

    /// Set to true to explicitly have no fill (even with theme)
    no_fill: bool = false,

    /// Stroke color (null = no stroke)
    stroke_color: ?Color = null,

    /// Stroke width in logical pixels
    stroke_width: f32 = 1.0,

    /// Viewbox size of the source SVG (default 24x24 for Material icons)
    viewbox: f32 = 24,

    /// Alt text for accessibility - describes the icon for screen readers
    /// If null, icon is treated as decorative (presentation role)
    alt: ?[]const u8 = null,

    /// Unique identifier for accessibility (defaults to path hash)
    id: ?[]const u8 = null,

    pub fn render(self: Svg, b: *ui.Builder) void {
        const t = b.theme();

        // Push accessible element for SVGs with alt text
        // SVGs without alt are treated as decorative (presentation)
        const layout_id = LayoutId.fromString(self.id orelse self.path);
        const a11y_pushed = if (self.alt) |alt_text|
            b.accessible(.{
                .layout_id = layout_id,
                .role = .img,
                .name = alt_text,
            })
        else
            // Decorative icon - explicitly mark as presentation
            b.accessible(.{
                .layout_id = layout_id,
                .role = .presentation,
            });
        defer if (a11y_pushed) b.accessibleEnd();

        // Determine final dimensions
        const w = self.width orelse self.size orelse 24;
        const h = self.height orelse self.size orelse 24;

        // Resolve fill color: explicit value OR theme default (unless no_fill)
        const fill_color: ?Color = if (self.no_fill)
            null
        else if (self.color) |c|
            c
        else
            t.text;

        const has_fill = fill_color != null;
        const final_color = fill_color orelse Color.transparent;

        // Emit the SVG primitive (atlas handles caching internally)
        b.box(.{
            .width = w,
            .height = h,
        }, .{
            ui.SvgPrimitive{
                .path = self.path,
                .width = w,
                .height = h,
                .color = final_color,
                .stroke_color = self.stroke_color,
                .stroke_width = self.stroke_width,
                .viewbox = self.viewbox,
                .has_fill = has_fill,
            },
        });
    }
};

/// Common icon paths (Material Design Icons subset)
pub const Icons = struct {
    // Navigation
    pub const arrow_back = "m12 19-7-7 7-7 M19 12H5";
    pub const arrow_forward = "M12 4l-1.41 1.41L16.17 11H4v2h12.17l-5.58 5.59L12 20l8-8z";
    pub const chevron_up = "M7.41 15.41L12 10.83l4.59 4.58L18 14l-6-6-6 6z";
    pub const chevron_down = "M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6z";
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

/// Lucide Icons - Beautiful stroke-based icons using SVG shape elements
/// These icons use circle, rect, line, polyline elements which are
/// automatically converted to path commands by SvgElementParser.
/// Source: https://lucide.dev (MIT License)
pub const Lucide = struct {
    // Navigation
    pub const arrow_left = "<path d=\"M12 19l-7-7 7-7\"/><path d=\"M19 12H5\"/>";
    pub const arrow_right = "<path d=\"M5 12h14\"/><path d=\"m12 5 7 7-7 7\"/>";
    pub const arrow_up = "<path d=\"m5 12 7-7 7 7\"/><path d=\"M12 19V5\"/>";
    pub const arrow_down = "<path d=\"M12 5v14\"/><path d=\"m19 12-7 7-7-7\"/>";
    pub const chevron_left = "<path d=\"m15 18-6-6 6-6\"/>";
    pub const chevron_right = "<path d=\"m9 18 6-6-6-6\"/>";
    pub const chevron_up = "<path d=\"m18 15-6-6-6 6\"/>";
    pub const chevron_down = "<path d=\"m6 9 6 6 6-6\"/>";
    pub const menu = "<line x1=\"4\" x2=\"20\" y1=\"12\" y2=\"12\"/><line x1=\"4\" x2=\"20\" y1=\"6\" y2=\"6\"/><line x1=\"4\" x2=\"20\" y1=\"18\" y2=\"18\"/>";
    pub const x = "<path d=\"M18 6 6 18\"/><path d=\"m6 6 12 12\"/>";
    pub const more_horizontal = "<circle cx=\"12\" cy=\"12\" r=\"1\"/><circle cx=\"19\" cy=\"12\" r=\"1\"/><circle cx=\"5\" cy=\"12\" r=\"1\"/>";
    pub const more_vertical = "<circle cx=\"12\" cy=\"12\" r=\"1\"/><circle cx=\"12\" cy=\"5\" r=\"1\"/><circle cx=\"12\" cy=\"19\" r=\"1\"/>";

    // Actions
    pub const check = "<path d=\"M20 6 9 17l-5-5\"/>";
    pub const plus = "<path d=\"M5 12h14\"/><path d=\"M12 5v14\"/>";
    pub const minus = "<path d=\"M5 12h14\"/>";
    pub const pencil = "<path d=\"M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z\"/>";
    pub const trash = "<path d=\"M3 6h18\"/><path d=\"M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6\"/><path d=\"M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2\"/>";
    pub const trash_2 = "<path d=\"M3 6h18\"/><path d=\"M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6\"/><path d=\"M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2\"/><line x1=\"10\" x2=\"10\" y1=\"11\" y2=\"17\"/><line x1=\"14\" x2=\"14\" y1=\"11\" y2=\"17\"/>";
    pub const search = "<circle cx=\"11\" cy=\"11\" r=\"8\"/><path d=\"m21 21-4.3-4.3\"/>";
    pub const settings = "<path d=\"M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/>";
    pub const copy = "<rect width=\"14\" height=\"14\" x=\"8\" y=\"8\" rx=\"2\" ry=\"2\"/><path d=\"M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2\"/>";
    pub const clipboard = "<rect width=\"8\" height=\"4\" x=\"8\" y=\"2\" rx=\"1\" ry=\"1\"/><path d=\"M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2\"/>";

    // Status & Feedback
    pub const check_circle = "<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"m9 12 2 2 4-4\"/>";
    pub const alert_circle = "<circle cx=\"12\" cy=\"12\" r=\"10\"/><line x1=\"12\" x2=\"12\" y1=\"8\" y2=\"12\"/><line x1=\"12\" x2=\"12.01\" y1=\"16\" y2=\"16\"/>";
    pub const alert_triangle = "<path d=\"m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3\"/><path d=\"M12 9v4\"/><path d=\"M12 17h.01\"/>";
    pub const info = "<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"M12 16v-4\"/><path d=\"M12 8h.01\"/>";
    pub const x_circle = "<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"m15 9-6 6\"/><path d=\"m9 9 6 6\"/>";
    pub const loader = "<path d=\"M12 2v4\"/><path d=\"m16.2 7.8 2.9-2.9\"/><path d=\"M18 12h4\"/><path d=\"m16.2 16.2 2.9 2.9\"/><path d=\"M12 18v4\"/><path d=\"m4.9 19.1 2.9-2.9\"/><path d=\"M2 12h4\"/><path d=\"m4.9 4.9 2.9 2.9\"/>";

    // Media
    pub const play = "<polygon points=\"6 3 20 12 6 21 6 3\"/>";
    pub const pause = "<rect width=\"4\" height=\"16\" x=\"6\" y=\"4\"/><rect width=\"4\" height=\"16\" x=\"14\" y=\"4\"/>";
    pub const skip_forward = "<polygon points=\"5 4 15 12 5 20 5 4\"/><line x1=\"19\" x2=\"19\" y1=\"5\" y2=\"19\"/>";
    pub const skip_back = "<polygon points=\"19 20 9 12 19 4 19 20\"/><line x1=\"5\" x2=\"5\" y1=\"19\" y2=\"5\"/>";
    pub const volume_2 = "<path d=\"M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z\"/><path d=\"M16 9a5 5 0 0 1 0 6\"/><path d=\"M19.364 18.364a9 9 0 0 0 0-12.728\"/>";
    pub const volume_x = "<path d=\"M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z\"/><line x1=\"22\" x2=\"16\" y1=\"9\" y2=\"15\"/><line x1=\"16\" x2=\"22\" y1=\"9\" y2=\"15\"/>";

    // Communication
    pub const mail = "<rect width=\"20\" height=\"16\" x=\"2\" y=\"4\" rx=\"2\"/><path d=\"m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7\"/>";
    pub const message_circle = "<path d=\"M7.9 20A9 9 0 1 0 4 16.1L2 22z\"/>";
    pub const send = "<path d=\"M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z\"/><path d=\"m21.854 2.147-10.94 10.939\"/>";
    pub const bell = "<path d=\"M10.268 21a2 2 0 0 0 3.464 0\"/><path d=\"M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326\"/>";

    // User & Account
    pub const user = "<circle cx=\"12\" cy=\"8\" r=\"5\"/><path d=\"M20 21a8 8 0 0 0-16 0\"/>";
    pub const users = "<path d=\"M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2\"/><circle cx=\"9\" cy=\"7\" r=\"4\"/><path d=\"M22 21v-2a4 4 0 0 0-3-3.87\"/><path d=\"M16 3.13a4 4 0 0 1 0 7.75\"/>";
    pub const log_in = "<path d=\"M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4\"/><polyline points=\"10 17 15 12 10 7\"/><line x1=\"15\" x2=\"3\" y1=\"12\" y2=\"12\"/>";
    pub const log_out = "<path d=\"M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4\"/><polyline points=\"16 17 21 12 16 7\"/><line x1=\"21\" x2=\"9\" y1=\"12\" y2=\"12\"/>";

    // Files & Folders
    pub const file = "<path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z\"/><path d=\"M14 2v4a2 2 0 0 0 2 2h4\"/>";
    pub const file_text = "<path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z\"/><path d=\"M14 2v4a2 2 0 0 0 2 2h4\"/><line x1=\"16\" x2=\"8\" y1=\"13\" y2=\"13\"/><line x1=\"16\" x2=\"8\" y1=\"17\" y2=\"17\"/><line x1=\"10\" x2=\"8\" y1=\"9\" y2=\"9\"/>";
    pub const folder = "<path d=\"M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2z\"/>";
    pub const folder_open = "<path d=\"m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2\"/>";
    pub const download = "<path d=\"M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4\"/><polyline points=\"7 10 12 15 17 10\"/><line x1=\"12\" x2=\"12\" y1=\"15\" y2=\"3\"/>";
    pub const upload = "<path d=\"M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4\"/><polyline points=\"17 8 12 3 7 8\"/><line x1=\"12\" x2=\"12\" y1=\"3\" y2=\"15\"/>";

    // UI Elements
    pub const home = "<path d=\"M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8\"/><path d=\"M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z\"/>";
    pub const star = "<polygon points=\"12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2\"/>";
    pub const heart = "<path d=\"M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7z\"/>";
    pub const bookmark = "<path d=\"m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z\"/>";
    pub const eye = "<path d=\"M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/>";
    pub const eye_off = "<path d=\"M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49\"/><path d=\"M14.084 14.158a3 3 0 0 1-4.242-4.242\"/><path d=\"M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143\"/><path d=\"m2 2 20 20\"/>";
    pub const lock = "<rect width=\"18\" height=\"11\" x=\"3\" y=\"11\" rx=\"2\" ry=\"2\"/><path d=\"M7 11V7a5 5 0 0 1 10 0v4\"/>";
    pub const unlock = "<rect width=\"18\" height=\"11\" x=\"3\" y=\"11\" rx=\"2\" ry=\"2\"/><path d=\"M7 11V7a5 5 0 0 1 9.9-1\"/>";
    pub const external_link = "<path d=\"M15 3h6v6\"/><path d=\"M10 14 21 3\"/><path d=\"M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6\"/>";
    pub const link = "<path d=\"M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71\"/><path d=\"M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71\"/>";
    pub const refresh_cw = "<path d=\"M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8\"/><path d=\"M21 3v5h-5\"/><path d=\"M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16\"/><path d=\"M8 16H3v5\"/>";
    pub const calendar = "<path d=\"M8 2v4\"/><path d=\"M16 2v4\"/><rect width=\"18\" height=\"18\" x=\"3\" y=\"4\" rx=\"2\"/><path d=\"M3 10h18\"/>";
    pub const clock = "<circle cx=\"12\" cy=\"12\" r=\"10\"/><polyline points=\"12 6 12 12 16 14\"/>";
    pub const filter = "<polygon points=\"22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3\"/>";
    pub const sliders = "<line x1=\"4\" x2=\"4\" y1=\"21\" y2=\"14\"/><line x1=\"4\" x2=\"4\" y1=\"10\" y2=\"3\"/><line x1=\"12\" x2=\"12\" y1=\"21\" y2=\"12\"/><line x1=\"12\" x2=\"12\" y1=\"8\" y2=\"3\"/><line x1=\"20\" x2=\"20\" y1=\"21\" y2=\"16\"/><line x1=\"20\" x2=\"20\" y1=\"12\" y2=\"3\"/><line x1=\"2\" x2=\"6\" y1=\"14\" y2=\"14\"/><line x1=\"10\" x2=\"14\" y1=\"8\" y2=\"8\"/><line x1=\"18\" x2=\"22\" y1=\"16\" y2=\"16\"/>";
    pub const grid = "<rect width=\"7\" height=\"7\" x=\"3\" y=\"3\" rx=\"1\"/><rect width=\"7\" height=\"7\" x=\"14\" y=\"3\" rx=\"1\"/><rect width=\"7\" height=\"7\" x=\"14\" y=\"14\" rx=\"1\"/><rect width=\"7\" height=\"7\" x=\"3\" y=\"14\" rx=\"1\"/>";
    pub const list = "<line x1=\"8\" x2=\"21\" y1=\"6\" y2=\"6\"/><line x1=\"8\" x2=\"21\" y1=\"12\" y2=\"12\"/><line x1=\"8\" x2=\"21\" y1=\"18\" y2=\"18\"/><line x1=\"3\" x2=\"3.01\" y1=\"6\" y2=\"6\"/><line x1=\"3\" x2=\"3.01\" y1=\"12\" y2=\"12\"/><line x1=\"3\" x2=\"3.01\" y1=\"18\" y2=\"18\"/>";
    pub const image = "<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\" ry=\"2\"/><circle cx=\"9\" cy=\"9\" r=\"2\"/><path d=\"m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21\"/>";
    pub const zap = "<path d=\"M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z\"/>";
    pub const code = "<polyline points=\"16 18 22 12 16 6\"/><polyline points=\"8 6 2 12 8 18\"/>";
    pub const terminal = "<polyline points=\"4 17 10 11 4 5\"/><line x1=\"12\" x2=\"20\" y1=\"19\" y2=\"19\"/>";
    pub const github = "<path d=\"M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.403 5.403 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4\"/><path d=\"M9 18c-4.51 2-5-2-7-2\"/>";
};
