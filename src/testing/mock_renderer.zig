//! Mock renderer for testing
//!
//! Tracks method calls without actual GPU operations.
//! Use this to test the layout→render pipeline without platform dependencies.
//!
//! Example:
//! ```zig
//! var renderer = try MockRenderer.init(std.testing.allocator);
//! defer renderer.deinit();
//!
//! try renderer.beginFrame(800, 600, 2.0);
//! renderer.renderScene(&scene);
//! renderer.endFrame();
//!
//! try std.testing.expectEqual(@as(u32, 1), renderer.begin_frame_count);
//! ```

const std = @import("std");
const interface_verify = @import("../core/interface_verify.zig");

pub const MockRenderer = struct {
    // =========================================================================
    // Call Tracking
    // =========================================================================

    begin_frame_count: u32 = 0,
    end_frame_count: u32 = 0,
    render_scene_count: u32 = 0,
    resize_count: u32 = 0,

    // =========================================================================
    // Last Values (for verification)
    // =========================================================================

    last_width: u32 = 0,
    last_height: u32 = 0,
    last_scale: f32 = 1.0,

    // =========================================================================
    // Controllable Behavior
    // =========================================================================

    should_fail_begin_frame: bool = false,
    should_fail_render: bool = false,

    // =========================================================================
    // Internal State
    // =========================================================================

    allocator: std.mem.Allocator,
    frame_in_progress: bool = false,

    const Self = @This();

    pub const Error = error{
        MockFailure,
        FrameNotStarted,
        FrameAlreadyStarted,
    };

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *Self) void {
        // Nothing to clean up for mock
    }

    // =========================================================================
    // Renderer Interface
    // =========================================================================

    pub fn beginFrame(self: *Self, width: u32, height: u32, scale: f32) !void {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);

        if (self.should_fail_begin_frame) {
            return Error.MockFailure;
        }

        if (self.frame_in_progress) {
            return Error.FrameAlreadyStarted;
        }

        self.begin_frame_count += 1;
        self.last_width = width;
        self.last_height = height;
        self.last_scale = scale;
        self.frame_in_progress = true;
    }

    pub fn endFrame(self: *Self) void {
        std.debug.assert(self.frame_in_progress);

        self.end_frame_count += 1;
        self.frame_in_progress = false;
    }

    /// Render a scene (accepts any scene-like type)
    pub fn renderScene(self: *Self, _: anytype) void {
        std.debug.assert(self.frame_in_progress);

        self.render_scene_count += 1;
    }

    /// Alias for renderScene to satisfy interface requirements
    pub fn render(self: *Self) void {
        self.render_scene_count += 1;
    }

    pub fn resize(self: *Self, width: u32, height: u32) void {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);

        self.resize_count += 1;
        self.last_width = width;
        self.last_height = height;
    }

    // =========================================================================
    // Test Utilities
    // =========================================================================

    /// Reset all counters and state (for test isolation)
    pub fn reset(self: *Self) void {
        self.begin_frame_count = 0;
        self.end_frame_count = 0;
        self.render_scene_count = 0;
        self.resize_count = 0;
        self.last_width = 0;
        self.last_height = 0;
        self.last_scale = 1.0;
        self.should_fail_begin_frame = false;
        self.should_fail_render = false;
        self.frame_in_progress = false;
    }

    /// Check if frame counts are balanced (begin == end)
    pub fn isFrameBalanced(self: *const Self) bool {
        return self.begin_frame_count == self.end_frame_count;
    }

    /// Get total render calls
    pub fn totalRenderCalls(self: *const Self) u32 {
        return self.render_scene_count;
    }

    // =========================================================================
    // Interface Verification
    // =========================================================================

    comptime {
        interface_verify.verifyRendererInterface(@This());
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MockRenderer tracks calls" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    try renderer.beginFrame(800, 600, 2.0);
    renderer.render();
    renderer.endFrame();

    try std.testing.expectEqual(@as(u32, 1), renderer.begin_frame_count);
    try std.testing.expectEqual(@as(u32, 1), renderer.end_frame_count);
    try std.testing.expectEqual(@as(u32, 1), renderer.render_scene_count);
    try std.testing.expectEqual(@as(u32, 800), renderer.last_width);
    try std.testing.expectEqual(@as(u32, 600), renderer.last_height);
    try std.testing.expectEqual(@as(f32, 2.0), renderer.last_scale);
    try std.testing.expect(renderer.isFrameBalanced());
}

test "MockRenderer can simulate failure" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    renderer.should_fail_begin_frame = true;
    try std.testing.expectError(MockRenderer.Error.MockFailure, renderer.beginFrame(800, 600, 1.0));
}

test "MockRenderer tracks resize" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    renderer.resize(1920, 1080);

    try std.testing.expectEqual(@as(u32, 1), renderer.resize_count);
    try std.testing.expectEqual(@as(u32, 1920), renderer.last_width);
    try std.testing.expectEqual(@as(u32, 1080), renderer.last_height);
}

test "MockRenderer reset clears state" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    try renderer.beginFrame(800, 600, 2.0);
    renderer.endFrame();
    renderer.resize(1024, 768);

    renderer.reset();

    try std.testing.expectEqual(@as(u32, 0), renderer.begin_frame_count);
    try std.testing.expectEqual(@as(u32, 0), renderer.end_frame_count);
    try std.testing.expectEqual(@as(u32, 0), renderer.resize_count);
    try std.testing.expectEqual(@as(u32, 0), renderer.last_width);
    try std.testing.expect(!renderer.frame_in_progress);
}

test "MockRenderer detects double beginFrame" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    try renderer.beginFrame(800, 600, 1.0);
    try std.testing.expectError(
        MockRenderer.Error.FrameAlreadyStarted,
        renderer.beginFrame(800, 600, 1.0),
    );
}

test "MockRenderer multiple frame cycles" {
    var renderer = try MockRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    // Simulate multiple frames
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try renderer.beginFrame(800, 600, 1.0);
        renderer.render();
        renderer.endFrame();
    }

    try std.testing.expectEqual(@as(u32, 5), renderer.begin_frame_count);
    try std.testing.expectEqual(@as(u32, 5), renderer.end_frame_count);
    try std.testing.expectEqual(@as(u32, 5), renderer.render_scene_count);
    try std.testing.expect(renderer.isFrameBalanced());
}
