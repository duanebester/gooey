//! DrawCommand — Tagged union mapping 1:1 to DrawContext methods.
//!
//! Each variant is a struct with named fields matching the DrawContext method
//! parameters. Text commands use `text_idx: u16` (index into TextPool), not
//! string slices — slices contain pointers which are not serializable and
//! break the "no allocation" rule.
//!
//! The tagged union enables:
//! - Exhaustive switch in replay (compiler forces handling every variant)
//! - Fixed size per command (largest variant determines union size)
//! - Comptime reflection for schema generation (`std.meta.fields`)
//! - Direct mapping to JSON objects with a `"tool"` discriminator

const std = @import("std");
const Color = @import("../core/geometry.zig").Color;

// =============================================================================
// Constants
// =============================================================================

/// Hard cap on draw commands per frame/batch. At 64 bytes per command this is
/// 256KB of command data — well within L2 cache on modern hardware.
pub const MAX_DRAW_COMMANDS: usize = 4096;

// =============================================================================
// DrawCommand
// =============================================================================

pub const DrawCommand = union(enum) {
    // === Fills ===
    fill_rect: FillRect,
    fill_rounded_rect: FillRoundedRect,
    fill_circle: FillCircle,
    fill_ellipse: FillEllipse,
    fill_triangle: FillTriangle,

    // === Strokes / Lines ===
    stroke_rect: StrokeRect,
    stroke_circle: StrokeCircle,
    line: Line,

    // === Text ===
    draw_text: DrawText,
    draw_text_centered: DrawTextCentered,

    // === Control ===
    set_background: SetBackground,

    // =========================================================================
    // Variant Structs
    // =========================================================================

    pub const FillRect = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
    };

    pub const FillRoundedRect = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32,
        color: Color,
    };

    pub const FillCircle = struct {
        cx: f32,
        cy: f32,
        radius: f32,
        color: Color,
    };

    pub const FillEllipse = struct {
        cx: f32,
        cy: f32,
        rx: f32,
        ry: f32,
        color: Color,
    };

    pub const FillTriangle = struct {
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        x3: f32,
        y3: f32,
        color: Color,
    };

    pub const StrokeRect = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        width: f32,
        color: Color,
    };

    pub const StrokeCircle = struct {
        cx: f32,
        cy: f32,
        radius: f32,
        width: f32,
        color: Color,
    };

    pub const Line = struct {
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        width: f32,
        color: Color,
    };

    pub const DrawText = struct {
        text_idx: u16,
        x: f32,
        y: f32,
        color: Color,
        font_size: f32,
    };

    pub const DrawTextCentered = struct {
        text_idx: u16,
        x: f32,
        y_center: f32,
        color: Color,
        font_size: f32,
    };

    pub const SetBackground = struct {
        color: Color,
    };

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Returns true if this command references a text pool entry.
    pub fn hasTextRef(self: DrawCommand) bool {
        return switch (self) {
            .draw_text, .draw_text_centered => true,
            else => false,
        };
    }

    /// Returns the text_idx for text commands, null otherwise.
    pub fn textIdx(self: DrawCommand) ?u16 {
        return switch (self) {
            .draw_text => |dt| dt.text_idx,
            .draw_text_centered => |dtc| dtc.text_idx,
            else => null,
        };
    }

    /// Returns the color for any command variant.
    pub fn getColor(self: DrawCommand) Color {
        return switch (self) {
            .fill_rect => |v| v.color,
            .fill_rounded_rect => |v| v.color,
            .fill_circle => |v| v.color,
            .fill_ellipse => |v| v.color,
            .fill_triangle => |v| v.color,
            .stroke_rect => |v| v.color,
            .stroke_circle => |v| v.color,
            .line => |v| v.color,
            .draw_text => |v| v.color,
            .draw_text_centered => |v| v.color,
            .set_background => |v| v.color,
        };
    }
};

// =============================================================================
// Compile-time Assertions (CLAUDE.md rules #3, #4)
// =============================================================================

comptime {
    // Cache-friendly replay: each command must fit in a cache line.
    std.debug.assert(@sizeOf(DrawCommand) <= 64);

    // Guard against adding variants without updating schema/replay.
    // 11 variants: 5 fills + 3 strokes/lines + 2 text + 1 control.
    const variant_count = std.meta.fields(DrawCommand).len;
    std.debug.assert(variant_count == 11);

    // Alignment should be reasonable for array packing.
    std.debug.assert(@alignOf(DrawCommand) <= 8);
}

// =============================================================================
// Tests
// =============================================================================

test "DrawCommand size fits in cache line" {
    try std.testing.expect(@sizeOf(DrawCommand) <= 64);
}

test "DrawCommand has exactly 11 variants" {
    const variant_count = std.meta.fields(DrawCommand).len;
    try std.testing.expectEqual(@as(usize, 11), variant_count);
}

test "DrawCommand fill_rect roundtrip" {
    const color = Color.hex(0xFF0000);
    const cmd = DrawCommand{ .fill_rect = .{ .x = 10, .y = 20, .w = 100, .h = 50, .color = color } };

    try std.testing.expect(!cmd.hasTextRef());
    try std.testing.expect(cmd.textIdx() == null);

    switch (cmd) {
        .fill_rect => |r| {
            try std.testing.expectApproxEqAbs(@as(f32, 10), r.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20), r.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 100), r.w, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 50), r.h, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "DrawCommand fill_triangle is largest variant" {
    // fill_triangle: 6 floats (24 bytes) + Color (16 bytes) = 40 bytes payload.
    // This should be the largest or tied for largest variant.
    const triangle_size = @sizeOf(DrawCommand.FillTriangle);
    const rect_size = @sizeOf(DrawCommand.FillRect);
    try std.testing.expect(triangle_size >= rect_size);
}

test "DrawCommand text commands reference text pool" {
    const text_cmd = DrawCommand{ .draw_text = .{
        .text_idx = 42,
        .x = 10,
        .y = 20,
        .color = Color.hex(0xFFFFFF),
        .font_size = 16,
    } };
    try std.testing.expect(text_cmd.hasTextRef());
    try std.testing.expectEqual(@as(u16, 42), text_cmd.textIdx().?);

    const centered_cmd = DrawCommand{ .draw_text_centered = .{
        .text_idx = 7,
        .x = 100,
        .y_center = 50,
        .color = Color.hex(0x000000),
        .font_size = 24,
    } };
    try std.testing.expect(centered_cmd.hasTextRef());
    try std.testing.expectEqual(@as(u16, 7), centered_cmd.textIdx().?);
}

test "DrawCommand getColor works for all variants" {
    const red = Color.hex(0xFF0000);

    const commands = [_]DrawCommand{
        .{ .fill_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = red } },
        .{ .fill_rounded_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .radius = 4, .color = red } },
        .{ .fill_circle = .{ .cx = 0, .cy = 0, .radius = 1, .color = red } },
        .{ .fill_ellipse = .{ .cx = 0, .cy = 0, .rx = 1, .ry = 2, .color = red } },
        .{ .fill_triangle = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .x3 = 0, .y3 = 1, .color = red } },
        .{ .stroke_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .width = 2, .color = red } },
        .{ .stroke_circle = .{ .cx = 0, .cy = 0, .radius = 1, .width = 2, .color = red } },
        .{ .line = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1, .width = 1, .color = red } },
        .{ .draw_text = .{ .text_idx = 0, .x = 0, .y = 0, .color = red, .font_size = 12 } },
        .{ .draw_text_centered = .{ .text_idx = 0, .x = 0, .y_center = 0, .color = red, .font_size = 12 } },
        .{ .set_background = .{ .color = red } },
    };

    for (commands) |cmd| {
        const c = cmd.getColor();
        try std.testing.expectApproxEqAbs(red.r, c.r, 0.001);
    }
}

test "DrawCommand non-text commands have no text ref" {
    const white = Color.hex(0xFFFFFF);
    const non_text = [_]DrawCommand{
        .{ .fill_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = white } },
        .{ .fill_circle = .{ .cx = 0, .cy = 0, .radius = 1, .color = white } },
        .{ .line = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1, .width = 1, .color = white } },
        .{ .set_background = .{ .color = white } },
    };

    for (non_text) |cmd| {
        try std.testing.expect(!cmd.hasTextRef());
        try std.testing.expect(cmd.textIdx() == null);
    }
}
