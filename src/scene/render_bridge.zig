//! Render Bridge - converts layout RenderCommands to GPU Scene primitives
//!
//! This module bridges the gap between the platform-agnostic layout system
//! and the GPU-specific scene rendering. It handles all type conversions
//! from layout types (Color, CornerRadius, etc.) to scene types (Hsla, Corners, etc.)
//!
//! By isolating these conversions here, the layout system remains decoupled
//! from rendering internals.

const std = @import("std");
const scene = @import("mod.zig");
const layout_types = @import("../layout/types.zig");
const render_commands = @import("../layout/render_commands.zig");

const RenderCommand = render_commands.RenderCommand;
const Color = layout_types.Color;
const CornerRadius = layout_types.CornerRadius;
const BorderWidth = layout_types.BorderWidth;

// ============================================================================
// Type Conversions
// ============================================================================

/// Convert layout Color (RGBA) to scene Hsla
pub fn colorToHsla(c: Color) scene.Hsla {
    return scene.Hsla.fromRgba(c.r, c.g, c.b, c.a);
}

/// Convert layout CornerRadius to scene Corners
pub fn cornerRadiusToCorners(cr: CornerRadius) scene.Corners {
    return .{
        .top_left = cr.top_left,
        .top_right = cr.top_right,
        .bottom_left = cr.bottom_left,
        .bottom_right = cr.bottom_right,
    };
}

/// Convert layout BorderWidth to scene Edges
pub fn borderWidthToEdges(bw: BorderWidth) scene.Edges {
    return .{
        .left = bw.left,
        .right = bw.right,
        .top = bw.top,
        .bottom = bw.bottom,
    };
}

// ============================================================================
// Command to Primitive Conversions
// ============================================================================

/// Convert a rectangle render command to a Quad
pub fn rectangleToQuad(cmd: RenderCommand) scene.Quad {
    const rect = cmd.data.rectangle;
    return .{
        .bounds_origin_x = cmd.bounding_box.x,
        .bounds_origin_y = cmd.bounding_box.y,
        .bounds_size_width = cmd.bounding_box.width,
        .bounds_size_height = cmd.bounding_box.height,
        .background = colorToHsla(rect.background_color),
        .corner_radii = cornerRadiusToCorners(rect.corner_radius),
    };
}

/// Convert a border render command to a Quad with border
pub fn borderToQuad(cmd: RenderCommand) scene.Quad {
    const border = cmd.data.border;
    return .{
        .bounds_origin_x = cmd.bounding_box.x,
        .bounds_origin_y = cmd.bounding_box.y,
        .bounds_size_width = cmd.bounding_box.width,
        .bounds_size_height = cmd.bounding_box.height,
        .background = scene.Hsla.transparent,
        .border_color = colorToHsla(border.color),
        .border_widths = borderWidthToEdges(border.width),
        .corner_radii = cornerRadiusToCorners(border.corner_radius),
    };
}

/// Convert a shadow render command to a Shadow primitive
pub fn shadowDataToShadow(cmd: RenderCommand) scene.Shadow {
    const shadow_data = cmd.data.shadow;
    return .{
        .content_origin_x = cmd.bounding_box.x,
        .content_origin_y = cmd.bounding_box.y,
        .content_size_width = cmd.bounding_box.width,
        .content_size_height = cmd.bounding_box.height,
        .blur_radius = shadow_data.blur_radius,
        .color = colorToHsla(shadow_data.color),
        .offset_x = shadow_data.offset_x,
        .offset_y = shadow_data.offset_y,
        .corner_radii = cornerRadiusToCorners(shadow_data.corner_radius),
    };
}

// ============================================================================
// Batch Rendering
// ============================================================================

/// Render all commands to a scene
/// Note: Text rendering requires TextSystem and is handled separately
pub fn renderCommandsToScene(commands: []const RenderCommand, s: *scene.Scene) !void {
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .shadow => {
                try s.insertShadow(shadowDataToShadow(cmd));
            },
            .rectangle => {
                try s.insertQuad(rectangleToQuad(cmd));
            },
            .border => {
                try s.insertQuad(borderToQuad(cmd));
            },
            .text => {
                // Text rendering requires TextSystem - handled separately
            },
            .scissor_start, .scissor_end => {
                // Scissor handled by renderer directly
            },
            .none, .svg, .image, .custom, .canvas => {},
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "color conversion" {
    const c = Color.rgb(1.0, 0.5, 0.0);
    const hsla = colorToHsla(c);
    try std.testing.expect(hsla.a == 1.0);
}

test "corner radius conversion" {
    const cr = CornerRadius.all(8.0);
    const corners = cornerRadiusToCorners(cr);
    try std.testing.expectEqual(@as(f32, 8.0), corners.top_left);
    try std.testing.expectEqual(@as(f32, 8.0), corners.bottom_right);
}
