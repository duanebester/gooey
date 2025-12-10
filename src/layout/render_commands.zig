//! Render commands output from the layout system
//!
//! The layout engine produces these commands, which are then
//! translated to gooey's rendering primitives (Quad, Shadow, etc.)

const std = @import("std");
const types = @import("types.zig");
const BoundingBox = types.BoundingBox;
const Color = types.Color;
const CornerRadius = types.CornerRadius;
const BorderWidth = types.BorderWidth;
const TextConfig = types.TextConfig;

/// Type of render command
pub const RenderCommandType = enum {
    none,
    shadow,
    rectangle,
    border,
    text,
    image,
    scissor_start,
    scissor_end,
    custom,
};

/// A single render command from layout
pub const RenderCommand = struct {
    /// Computed bounding box
    bounding_box: BoundingBox,
    /// Type of command
    command_type: RenderCommandType,
    /// Z-index for layering (higher = on top)
    z_index: i16 = 0,
    /// Element ID this command belongs to
    id: u32 = 0,
    /// Command-specific data
    data: RenderData = .{ .none = {} },
};

/// Command-specific render data
pub const RenderData = union(RenderCommandType) {
    none: void,
    shadow: ShadowData,
    rectangle: RectangleData,
    border: BorderData,
    text: TextData,
    image: ImageData,
    scissor_start: ScissorData,
    scissor_end: void,
    custom: CustomData,
};

/// Data for shadow rendering
pub const ShadowData = struct {
    blur_radius: f32,
    color: Color,
    offset_x: f32,
    offset_y: f32,
    corner_radius: CornerRadius = .{},
};

/// Data for rectangle rendering
pub const RectangleData = struct {
    background_color: Color,
    corner_radius: CornerRadius = .{},
};

/// Data for border rendering
pub const BorderData = struct {
    color: Color,
    width: BorderWidth,
    corner_radius: CornerRadius = .{},
};

/// Data for text rendering
pub const TextData = struct {
    text: []const u8,
    color: Color,
    font_id: u16,
    font_size: u16,
    letter_spacing: i16 = 0,
};

/// Data for image rendering
pub const ImageData = struct {
    image_data: *anyopaque,
    source_rect: ?BoundingBox = null,
};

/// Data for scissor/clip regions
pub const ScissorData = struct {
    clip_bounds: BoundingBox,
};

/// Data for custom rendering
pub const CustomData = struct {
    user_data: ?*anyopaque = null,
};

/// List of render commands (typically per-frame)
pub const RenderCommandList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(RenderCommand),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .commands = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.commands.deinit(self.allocator);
    }

    pub fn clear(self: *Self) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn append(self: *Self, cmd: RenderCommand) !void {
        try self.commands.append(self.allocator, cmd);
    }

    pub fn items(self: *const Self) []const RenderCommand {
        return self.commands.items;
    }

    pub fn sortByZIndex(self: *Self) void {
        std.sort.pdq(RenderCommand, self.commands.items, {}, struct {
            fn lessThan(_: void, a: RenderCommand, b: RenderCommand) bool {
                return a.z_index < b.z_index;
            }
        }.lessThan);
    }
};

// ============================================================================
// Conversion to gooey rendering primitives
// ============================================================================

const scene = @import("../core/scene.zig");

/// Convert layout Color to scene Hsla
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

/// Render all commands to a scene
pub fn renderCommandsToScene(commands: []const RenderCommand, s: *scene.Scene) !void {
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .shadow => {
                const shadow_data = cmd.data.shadow;
                try s.insertShadow(scene.Shadow{
                    .content_origin_x = cmd.bounding_box.x,
                    .content_origin_y = cmd.bounding_box.y,
                    .content_size_width = cmd.bounding_box.width,
                    .content_size_height = cmd.bounding_box.height,
                    .blur_radius = shadow_data.blur_radius,
                    .color = colorToHsla(shadow_data.color),
                    .offset_x = shadow_data.offset_x,
                    .offset_y = shadow_data.offset_y,
                    .corner_radii = cornerRadiusToCorners(shadow_data.corner_radius),
                });
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
            .none, .image, .custom => {},
        }
    }
}

test "color conversion" {
    const c = Color.rgb(1.0, 0.5, 0.0);
    const hsla = colorToHsla(c);
    try std.testing.expect(hsla.a == 1.0);
}
