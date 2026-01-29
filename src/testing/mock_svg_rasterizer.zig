//! Mock SVG rasterizer for testing
//!
//! Simulates SVG rasterization without platform graphics dependencies.
//! Use this to test SVG rendering pipelines in isolation.
//!
//! Example:
//! ```zig
//! var rasterizer = MockSvgRasterizer.init();
//!
//! const result = try rasterizer.rasterize(
//!     std.testing.allocator,
//!     "M0 0 L10 10",
//!     24.0,
//!     48,
//!     &buffer,
//! );
//!
//! try std.testing.expectEqual(@as(u32, 1), rasterizer.rasterize_count);
//! try std.testing.expectEqual(@as(u32, 48), result.width);
//! ```

const std = @import("std");
const interface_verify = @import("../core/interface_verify.zig");

// =============================================================================
// Types (matching real SVG rasterizer interface)
// =============================================================================

pub const RasterizedSvg = struct {
    width: u32,
    height: u32,
    offset_x: i16 = 0,
    offset_y: i16 = 0,
};

pub const RasterizeError = error{
    /// SVG path data is empty or invalid
    EmptyPath,
    /// Graphics system error
    GraphicsError,
    /// Output buffer is too small
    BufferTooSmall,
    /// Out of memory
    OutOfMemory,
    /// Mock-specific: simulated failure
    MockFailure,
};

pub const StrokeOptions = struct {
    enabled: bool = false,
    width: f32 = 1.0,
    color: ?[4]u8 = null, // RGBA, null = use path's stroke color
};

// =============================================================================
// Mock Implementation
// =============================================================================

pub const MockSvgRasterizer = struct {
    // =========================================================================
    // Call Tracking
    // =========================================================================

    rasterize_count: u32 = 0,
    rasterize_with_options_count: u32 = 0,

    // =========================================================================
    // Last Values (for verification)
    // =========================================================================

    last_path_data: ?[]const u8 = null,
    last_viewbox: f32 = 0,
    last_device_size: u32 = 0,
    last_fill: bool = true,
    last_stroke_options: StrokeOptions = .{},

    // =========================================================================
    // Controllable Behavior
    // =========================================================================

    should_fail: bool = false,
    fail_error: RasterizeError = RasterizeError.MockFailure,

    /// Custom dimensions to return (if set)
    result_width: ?u32 = null,
    result_height: ?u32 = null,
    result_offset_x: i16 = 0,
    result_offset_y: i16 = 0,

    /// Fill buffer with this value (default: 0 = transparent)
    fill_value: u8 = 0,

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init() Self {
        return Self{};
    }

    // No deinit needed - no allocations

    // =========================================================================
    // SVG Rasterizer Interface
    // =========================================================================

    /// Rasterize SVG path data to RGBA buffer
    pub fn rasterize(
        self: *Self,
        allocator: std.mem.Allocator,
        path_data: []const u8,
        viewbox: f32,
        device_size: u32,
        buffer: []u8,
    ) RasterizeError!RasterizedSvg {
        return self.rasterizeWithOptions(
            allocator,
            path_data,
            viewbox,
            device_size,
            buffer,
            true,
            .{},
        );
    }

    /// Rasterize SVG path data with extended options
    pub fn rasterizeWithOptions(
        self: *Self,
        _: std.mem.Allocator,
        path_data: []const u8,
        viewbox: f32,
        device_size: u32,
        buffer: []u8,
        fill: bool,
        stroke_options: StrokeOptions,
    ) RasterizeError!RasterizedSvg {
        // Track calls
        self.rasterize_count += 1;
        self.rasterize_with_options_count += 1;

        // Store last values
        self.last_path_data = path_data;
        self.last_viewbox = viewbox;
        self.last_device_size = device_size;
        self.last_fill = fill;
        self.last_stroke_options = stroke_options;

        // Check for simulated failure
        if (self.should_fail) {
            return self.fail_error;
        }

        // Validate inputs
        if (path_data.len == 0) {
            return RasterizeError.EmptyPath;
        }

        const required_size = device_size * device_size * 4; // RGBA
        if (buffer.len < required_size) {
            return RasterizeError.BufferTooSmall;
        }

        // Fill buffer with test pattern
        @memset(buffer[0..required_size], self.fill_value);

        // Return result
        return RasterizedSvg{
            .width = self.result_width orelse device_size,
            .height = self.result_height orelse device_size,
            .offset_x = self.result_offset_x,
            .offset_y = self.result_offset_y,
        };
    }

    // =========================================================================
    // Test Utilities
    // =========================================================================

    /// Reset all counters and state (for test isolation)
    pub fn reset(self: *Self) void {
        self.rasterize_count = 0;
        self.rasterize_with_options_count = 0;
        self.last_path_data = null;
        self.last_viewbox = 0;
        self.last_device_size = 0;
        self.last_fill = true;
        self.last_stroke_options = .{};
        self.should_fail = false;
        self.fail_error = RasterizeError.MockFailure;
        self.result_width = null;
        self.result_height = null;
        self.result_offset_x = 0;
        self.result_offset_y = 0;
        self.fill_value = 0;
    }

    /// Configure to return specific dimensions
    pub fn setResultDimensions(self: *Self, width: u32, height: u32) void {
        self.result_width = width;
        self.result_height = height;
    }

    /// Configure to return specific offsets
    pub fn setResultOffsets(self: *Self, offset_x: i16, offset_y: i16) void {
        self.result_offset_x = offset_x;
        self.result_offset_y = offset_y;
    }

    /// Configure failure mode
    pub fn setFailure(self: *Self, err: RasterizeError) void {
        self.should_fail = true;
        self.fail_error = err;
    }

    // =========================================================================
    // Interface Verification
    // =========================================================================

    comptime {
        interface_verify.verifySvgRasterizerInterface(@This());
    }
};

// =============================================================================
// Module-level functions (matching real rasterizer module interface)
// =============================================================================

/// Global mock instance for module-level function tests
var global_mock: ?*MockSvgRasterizer = null;

/// Set the global mock instance (for module-level function testing)
pub fn setGlobalMock(mock: *MockSvgRasterizer) void {
    global_mock = mock;
}

/// Clear the global mock instance
pub fn clearGlobalMock() void {
    global_mock = null;
}

/// Module-level rasterize (delegates to global mock or returns error)
pub fn rasterize(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
) RasterizeError!RasterizedSvg {
    if (global_mock) |mock| {
        return mock.rasterize(allocator, path_data, viewbox, device_size, buffer);
    }
    return RasterizeError.GraphicsError;
}

/// Module-level rasterizeWithOptions (delegates to global mock or returns error)
pub fn rasterizeWithOptions(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
    fill: bool,
    stroke_options: StrokeOptions,
) RasterizeError!RasterizedSvg {
    if (global_mock) |mock| {
        return mock.rasterizeWithOptions(allocator, path_data, viewbox, device_size, buffer, fill, stroke_options);
    }
    return RasterizeError.GraphicsError;
}

// =============================================================================
// Module Interface Verification
// =============================================================================

comptime {
    interface_verify.verifySvgRasterizerModule(@This());
}

// =============================================================================
// Tests
// =============================================================================

test "MockSvgRasterizer basic rasterize" {
    var rasterizer = MockSvgRasterizer.init();

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = try rasterizer.rasterize(
        std.testing.allocator,
        "M0 0 L10 10",
        24.0,
        48,
        &buffer,
    );

    try std.testing.expectEqual(@as(u32, 1), rasterizer.rasterize_count);
    try std.testing.expectEqual(@as(u32, 48), result.width);
    try std.testing.expectEqual(@as(u32, 48), result.height);
    try std.testing.expectEqual(@as(i16, 0), result.offset_x);
    try std.testing.expectEqual(@as(i16, 0), result.offset_y);
}

test "MockSvgRasterizer tracks last values" {
    var rasterizer = MockSvgRasterizer.init();

    var buffer: [64 * 64 * 4]u8 = undefined;
    _ = try rasterizer.rasterizeWithOptions(
        std.testing.allocator,
        "M5 5 L20 20 Z",
        32.0,
        64,
        &buffer,
        false,
        .{ .enabled = true, .width = 2.0 },
    );

    try std.testing.expectEqualStrings("M5 5 L20 20 Z", rasterizer.last_path_data.?);
    try std.testing.expectEqual(@as(f32, 32.0), rasterizer.last_viewbox);
    try std.testing.expectEqual(@as(u32, 64), rasterizer.last_device_size);
    try std.testing.expect(!rasterizer.last_fill);
    try std.testing.expect(rasterizer.last_stroke_options.enabled);
    try std.testing.expectEqual(@as(f32, 2.0), rasterizer.last_stroke_options.width);
}

test "MockSvgRasterizer can simulate failure" {
    var rasterizer = MockSvgRasterizer.init();
    rasterizer.setFailure(RasterizeError.GraphicsError);

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = rasterizer.rasterize(
        std.testing.allocator,
        "M0 0 L10 10",
        24.0,
        48,
        &buffer,
    );

    try std.testing.expectError(RasterizeError.GraphicsError, result);
    try std.testing.expectEqual(@as(u32, 1), rasterizer.rasterize_count);
}

test "MockSvgRasterizer returns EmptyPath for empty data" {
    var rasterizer = MockSvgRasterizer.init();

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = rasterizer.rasterize(
        std.testing.allocator,
        "",
        24.0,
        48,
        &buffer,
    );

    try std.testing.expectError(RasterizeError.EmptyPath, result);
}

test "MockSvgRasterizer returns BufferTooSmall" {
    var rasterizer = MockSvgRasterizer.init();

    var buffer: [100]u8 = undefined; // Too small for 48x48x4
    const result = rasterizer.rasterize(
        std.testing.allocator,
        "M0 0 L10 10",
        24.0,
        48,
        &buffer,
    );

    try std.testing.expectError(RasterizeError.BufferTooSmall, result);
}

test "MockSvgRasterizer custom dimensions" {
    var rasterizer = MockSvgRasterizer.init();
    rasterizer.setResultDimensions(32, 24);
    rasterizer.setResultOffsets(-5, 10);

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = try rasterizer.rasterize(
        std.testing.allocator,
        "M0 0 L10 10",
        24.0,
        48,
        &buffer,
    );

    try std.testing.expectEqual(@as(u32, 32), result.width);
    try std.testing.expectEqual(@as(u32, 24), result.height);
    try std.testing.expectEqual(@as(i16, -5), result.offset_x);
    try std.testing.expectEqual(@as(i16, 10), result.offset_y);
}

test "MockSvgRasterizer fills buffer" {
    var rasterizer = MockSvgRasterizer.init();
    rasterizer.fill_value = 0xFF;

    var buffer: [4 * 4 * 4]u8 = undefined;
    @memset(&buffer, 0);

    _ = try rasterizer.rasterize(
        std.testing.allocator,
        "M0 0 L1 1",
        4.0,
        4,
        &buffer,
    );

    // All bytes should be 0xFF
    for (buffer) |byte| {
        try std.testing.expectEqual(@as(u8, 0xFF), byte);
    }
}

test "MockSvgRasterizer reset clears state" {
    var rasterizer = MockSvgRasterizer.init();

    var buffer: [48 * 48 * 4]u8 = undefined;
    _ = try rasterizer.rasterize(
        std.testing.allocator,
        "M0 0 L10 10",
        24.0,
        48,
        &buffer,
    );

    rasterizer.setFailure(RasterizeError.OutOfMemory);
    rasterizer.setResultDimensions(100, 200);

    rasterizer.reset();

    try std.testing.expectEqual(@as(u32, 0), rasterizer.rasterize_count);
    try std.testing.expect(rasterizer.last_path_data == null);
    try std.testing.expect(!rasterizer.should_fail);
    try std.testing.expect(rasterizer.result_width == null);
}

test "MockSvgRasterizer global mock" {
    var rasterizer = MockSvgRasterizer.init();
    setGlobalMock(&rasterizer);
    defer clearGlobalMock();

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = try rasterize(
        std.testing.allocator,
        "M0 0 L10 10",
        24.0,
        48,
        &buffer,
    );

    try std.testing.expectEqual(@as(u32, 48), result.width);
    try std.testing.expectEqual(@as(u32, 1), rasterizer.rasterize_count);
}

test "MockSvgRasterizer global mock not set" {
    clearGlobalMock();

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = rasterize(
        std.testing.allocator,
        "M0 0 L10 10",
        24.0,
        48,
        &buffer,
    );

    try std.testing.expectError(RasterizeError.GraphicsError, result);
}

test "MockSvgRasterizer multiple calls" {
    var rasterizer = MockSvgRasterizer.init();

    var buffer: [48 * 48 * 4]u8 = undefined;

    _ = try rasterizer.rasterize(std.testing.allocator, "path1", 24.0, 48, &buffer);
    _ = try rasterizer.rasterize(std.testing.allocator, "path2", 24.0, 48, &buffer);
    _ = try rasterizer.rasterize(std.testing.allocator, "path3", 24.0, 48, &buffer);

    try std.testing.expectEqual(@as(u32, 3), rasterizer.rasterize_count);
    try std.testing.expectEqualStrings("path3", rasterizer.last_path_data.?);
}
