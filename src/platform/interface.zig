const std = @import("std");
const geometry = @import("../geometry/geometry.zig");
const ResourceLimits = @import("../core/limits.zig").ResourceLimits;
const TitleBar = @import("../core/events.zig").TitleBar;
const window_registry = @import("window_registry.zig");

pub const WindowId = window_registry.WindowId;

pub const WindowRegistry = window_registry.WindowRegistry;

pub const render_delay_ms_max: u32 = 60_000;

pub const CursorShape = enum(u8) {
    default,
    text,
    pointer,
    resize_left_right,
    resize_up_down,
};

pub const scale_steps_per_unit: u32 = 120;

const scale_step_tolerance: f64 = 1e-3;

pub fn scaleFromSteps(steps: u32) f64 {
    std.debug.assert(steps > 0);
    const scale = @as(f64, @floatFromInt(steps)) / @as(f64, @floatFromInt(scale_steps_per_unit));
    std.debug.assert(scale > 0);
    return scale;
}

pub fn devicePxFromLogical(logical_px: u32, scale_factor: f64) u32 {
    std.debug.assert(logical_px > 0);
    std.debug.assert(scale_factor > 0);
    const steps = scale_factor * @as(f64, @floatFromInt(scale_steps_per_unit));
    const steps_nearest = @round(steps);
    var device_px: u64 = 0;
    if (@abs(steps - steps_nearest) <= scale_step_tolerance) {
        const steps_whole: u64 = @intFromFloat(steps_nearest);
        const product = @as(u64, logical_px) * steps_whole + scale_steps_per_unit / 2;
        device_px = @divFloor(product, scale_steps_per_unit);
    } else {
        device_px = @intFromFloat(@round(@as(f64, @floatFromInt(logical_px)) * scale_factor));
    }
    std.debug.assert(device_px <= std.math.maxInt(u32));
    return @intCast(device_px);
}

test "fractional scales convert exactly and round buffer sizes half away from zero" {
    try std.testing.expectEqual(1.25, scaleFromSteps(150));
    try std.testing.expectEqual(1.5, scaleFromSteps(180));
    try std.testing.expectEqual(1.75, scaleFromSteps(210));
    const cases = [_]struct { steps: u32, logical_px: u32, device_px: u32 }{
        .{ .steps = 150, .logical_px = 2, .device_px = 3 },
        .{ .steps = 150, .logical_px = 403, .device_px = 504 },
        .{ .steps = 180, .logical_px = 401, .device_px = 602 },
        .{ .steps = 180, .logical_px = 400, .device_px = 600 },
        .{ .steps = 210, .logical_px = 401, .device_px = 702 },
        .{ .steps = 210, .logical_px = 402, .device_px = 704 },
        .{ .steps = 240, .logical_px = 401, .device_px = 802 },
        .{ .steps = 156, .logical_px = 405, .device_px = 527 },
    };
    for (cases) |case| {
        const scale: f32 = @floatCast(scaleFromSteps(case.steps));
        try std.testing.expectEqual(case.device_px, devicePxFromLogical(case.logical_px, scale));
    }
    try std.testing.expectEqual(3840, devicePxFromLogical(2561, 3840.0 / 2561.0));
}

pub const RendererCapabilities = struct {
    max_texture_size: u32 = 4096,
    msaa: bool = true,
    msaa_sample_count: u32 = 4,
    unified_memory: bool = false,
    name: []const u8 = "unknown",
};

pub const PathPromptOptions = struct {
    files: bool,
    directories: bool,
    multiple: bool,
};

pub const SavePromptOptions = struct {
    directory: ?[]const u8,
    suggested_name: ?[]const u8,
};

pub const PathPromptResult = struct {
    paths: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: PathPromptResult) void {
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
    }
};

pub const WindowOptions = struct {
    title: []const u8 = "Gooey Window",

    width: f64 = 800,

    height: f64 = 600,

    background_color: geometry.Color = geometry.Color.rgba(0.2, 0.2, 0.25, 1.0),

    min_size: ?geometry.Size(f64) = null,

    max_size: ?geometry.Size(f64) = null,

    centered: bool = true,

    title_bar: TitleBar = .standard,

    limits: ResourceLimits,
};

pub fn minSize(width: u32, height: u32) ?geometry.Size(f64) {
    if (width == 0 and height == 0) return null;
    const size = geometry.Size(f64).init(
        @floatFromInt(@max(width, 1)),
        @floatFromInt(@max(height, 1)),
    );
    std.debug.assert(size.width >= 1);
    std.debug.assert(size.height >= 1);
    return size;
}

test "minSize sets no minimum for 0 by 0 and keeps a set axis exactly" {
    try std.testing.expectEqual(@as(?geometry.Size(f64), null), minSize(0, 0));
    const width_only = minSize(400, 0).?;
    try std.testing.expectEqual(@as(f64, 400), width_only.width);
    try std.testing.expectEqual(@as(f64, 1), width_only.height);
    const both = minSize(320, 240).?;
    try std.testing.expectEqual(@as(f64, 320), both.width);
    try std.testing.expectEqual(@as(f64, 240), both.height);
}
