//! Animation System for Gooey
//!
//! Provides time-based interpolation for smooth UI transitions.
//! Integrates with WidgetStore for retained state management.
//!
//! ## Quick Start
//!
//! ```zig
//! fn render(cx: *Cx) void {
//!     const anim = cx.animate("fade-in", .{ .duration_ms = 300 });
//!     cx.box(.{
//!         .background = ui.Color.rgba(0.2, 0.5, 1.0, anim.progress),
//!     }, .{});
//! }
//! ```

const std = @import("std");
const platform = @import("../platform/mod.zig");
// =============================================================================
// Animation ID (hashed, like LayoutId)
// =============================================================================

/// Hash-based animation ID for O(1) lookup without string allocation
pub const AnimationId = struct {
    id: u32,

    const Self = @This();

    /// Create from compile-time string literal (hashed at comptime)
    pub fn init(comptime str: []const u8) Self {
        return .{ .id = comptime hashString(str) };
    }

    /// Create from runtime string (hashed at runtime)
    pub fn fromString(str: []const u8) Self {
        return .{ .id = hashString(str) };
    }

    /// Create from raw u32 hash
    pub fn fromHash(hash: u32) Self {
        return .{ .id = hash };
    }
};

/// Jenkins one-at-a-time hash (same as LayoutId)
pub fn hashString(str: []const u8) u32 {
    var hash: u32 = 0;
    for (str) |c| {
        hash +%= c;
        hash +%= hash << 10;
        hash ^= hash >> 6;
    }
    hash +%= hash << 3;
    hash ^= hash >> 11;
    hash +%= hash << 15;
    return if (hash == 0) 1 else hash;
}

// =============================================================================
// Duration
// =============================================================================

pub const Duration = struct {
    ms: u32,

    pub const zero = Duration{ .ms = 0 };

    pub fn millis(ms: u32) Duration {
        return .{ .ms = ms };
    }

    pub fn seconds(s: f32) Duration {
        return .{ .ms = @intFromFloat(s * 1000.0) };
    }

    pub fn asSeconds(self: Duration) f32 {
        return @as(f32, @floatFromInt(self.ms)) / 1000.0;
    }

    pub fn asMillis(self: Duration) u32 {
        return self.ms;
    }
};

// =============================================================================
// Easing Functions
// =============================================================================

/// Easing function signature: takes linear time (0-1), returns eased time (0-1)
pub const EasingFn = *const fn (f32) f32;

pub const Easing = struct {
    /// Linear - no easing, constant speed
    pub fn linear(t: f32) f32 {
        return t;
    }

    /// Quadratic ease-in - slow start, fast end
    pub fn easeIn(t: f32) f32 {
        return t * t;
    }

    /// Quadratic ease-out - fast start, slow end (most common for UI)
    pub fn easeOut(t: f32) f32 {
        return 1.0 - (1.0 - t) * (1.0 - t);
    }

    /// Quadratic ease-in-out - slow start and end
    pub fn easeInOut(t: f32) f32 {
        if (t < 0.5) {
            return 2.0 * t * t;
        } else {
            const x = -2.0 * t + 2.0;
            return 1.0 - x * x / 2.0;
        }
    }

    /// Cubic ease-out - snappier than quadratic
    pub fn easeOutCubic(t: f32) f32 {
        const x = 1.0 - t;
        return 1.0 - x * x * x;
    }

    /// Cubic ease-in-out
    pub fn easeInOutCubic(t: f32) f32 {
        if (t < 0.5) {
            return 4.0 * t * t * t;
        } else {
            const x = -2.0 * t + 2.0;
            return 1.0 - x * x * x / 2.0;
        }
    }

    /// Quint ease-out - very snappy, great for menus
    pub fn easeOutQuint(t: f32) f32 {
        const x = 1.0 - t;
        return 1.0 - x * x * x * x * x;
    }

    /// Exponential ease-out - extremely snappy start
    pub fn easeOutExpo(t: f32) f32 {
        if (t >= 1.0) return 1.0;
        return 1.0 - std.math.pow(f32, 2.0, -10.0 * t);
    }

    /// Back ease-out - slight overshoot then settle
    pub fn easeOutBack(t: f32) f32 {
        const c1: f32 = 1.70158;
        const c3: f32 = c1 + 1.0;
        const x = t - 1.0;
        return 1.0 + c3 * x * x * x + c1 * x * x;
    }

    /// Elastic ease-out - spring/wobble effect
    pub fn easeOutElastic(t: f32) f32 {
        if (t <= 0.0) return 0.0;
        if (t >= 1.0) return 1.0;
        const c4 = (2.0 * std.math.pi) / 3.0;
        return std.math.pow(f32, 2.0, -10.0 * t) * @sin((t * 10.0 - 0.75) * c4) + 1.0;
    }

    /// Bounce ease-out - bouncing ball effect
    pub fn bounce(t: f32) f32 {
        const n1: f32 = 7.5625;
        const d1: f32 = 2.75;
        var tt = t;

        if (tt < 1.0 / d1) {
            return n1 * tt * tt;
        } else if (tt < 2.0 / d1) {
            tt -= 1.5 / d1;
            return n1 * tt * tt + 0.75;
        } else if (tt < 2.5 / d1) {
            tt -= 2.25 / d1;
            return n1 * tt * tt + 0.9375;
        } else {
            tt -= 2.625 / d1;
            return n1 * tt * tt + 0.984375;
        }
    }
};

// =============================================================================
// Animation Configuration
// =============================================================================

pub const AnimationConfig = struct {
    duration_ms: u32 = 200,
    easing: EasingFn = Easing.easeOut,
    delay_ms: u32 = 0,
    mode: Mode = .once,

    pub const Mode = enum {
        /// Play once and hold at end value
        once,
        /// Play once then reset (good for "pulse" effects)
        once_reset,
        /// Loop forever
        loop,
        /// Ping-pong back and forth
        ping_pong,
    };

    /// Convenience: quick fade-in
    pub const fade_in = AnimationConfig{ .duration_ms = 200 };

    /// Convenience: quick fade-out
    pub const fade_out = AnimationConfig{ .duration_ms = 150, .easing = Easing.easeIn };

    /// Convenience: snappy pop-in
    pub const pop_in = AnimationConfig{ .duration_ms = 250, .easing = Easing.easeOutBack };

    /// Convenience: smooth slide
    pub const slide = AnimationConfig{ .duration_ms = 300, .easing = Easing.easeOutCubic };

    /// Convenience: pulse effect
    pub const pulse = AnimationConfig{ .duration_ms = 150, .mode = .once_reset };

    /// Convenience: continuous pulse
    pub const pulse_loop = AnimationConfig{ .duration_ms = 1000, .easing = Easing.easeInOut, .mode = .ping_pong };
};

// =============================================================================
// Animation State (stored in WidgetStore)
// =============================================================================

pub const AnimationState = struct {
    /// When the animation started (milliseconds, from platform.time)
    start_time: i64,
    /// Configured duration
    duration_ms: u32,
    /// Configured delay before starting
    delay_ms: u32,
    /// Easing function to apply
    easing: EasingFn,
    /// Playback mode
    mode: AnimationConfig.Mode,
    /// Is this animation currently running?
    running: bool,
    /// For ping-pong: current direction (true = forward)
    forward: bool,
    /// Generation counter - incremented on restart to detect stale handles
    generation: u32,
    /// Trigger hash for animateOn (embedded to eliminate separate HashMap)
    trigger_hash: u64,

    const Self = @This();

    pub fn init(config: AnimationConfig) Self {
        return .{
            .start_time = platform.time.milliTimestamp(),
            .duration_ms = config.duration_ms,
            .delay_ms = config.delay_ms,
            .easing = config.easing,
            .mode = config.mode,
            .running = true,
            .forward = true,
            .generation = 0,
            .trigger_hash = 0,
        };
    }

    pub fn initWithTrigger(config: AnimationConfig, trigger_hash: u64) @This() {
        var state = init(config);
        state.trigger_hash = trigger_hash;
        return state;
    }

    /// Initialize in a settled/idle state (not running).
    /// Use this when creating animations for components that start in their
    /// "default" state (e.g., modals that start closed).
    pub fn initSettled(config: AnimationConfig, trigger_hash: u64) @This() {
        return .{
            .start_time = 0,
            .duration_ms = config.duration_ms,
            .delay_ms = config.delay_ms,
            .easing = config.easing,
            .mode = config.mode,
            .running = false,
            .forward = true,
            .generation = 0,
            .trigger_hash = trigger_hash,
        };
    }
};

// =============================================================================
// Animation Handle (returned to user code)
// =============================================================================

/// Lightweight handle returned by cx.animate()
/// Contains the computed progress value and control methods
pub const AnimationHandle = struct {
    /// Current progress (0.0 to 1.0), with easing applied
    progress: f32,
    /// Raw linear progress (0.0 to 1.0), without easing
    linear_progress: f32,
    /// Is the animation still running?
    running: bool,
    /// Pointer back to state for control methods (null if animation doesn't exist)
    state: ?*AnimationState,

    const Self = @This();

    /// Animation that's complete (progress = 1.0)
    pub const complete = Self{
        .progress = 1.0,
        .linear_progress = 1.0,
        .running = false,
        .state = null,
    };

    /// Animation that hasn't started (progress = 0.0)
    pub const idle = Self{
        .progress = 0.0,
        .linear_progress = 0.0,
        .running = false,
        .state = null,
    };

    /// Restart the animation from the beginning
    pub fn restart(self: Self) void {
        if (self.state) |s| {
            s.start_time = platform.time.milliTimestamp();
            s.running = true;
            s.forward = true;
            s.generation +%= 1;
        }
    }

    /// Stop the animation at current position
    pub fn stop(self: Self) void {
        if (self.state) |s| {
            s.running = false;
        }
    }

    /// Resume a stopped animation
    pub fn cont(self: Self) void {
        if (self.state) |s| {
            s.running = true;
        }
    }

    /// Reverse direction (for manual control)
    pub fn reverse(self: Self) void {
        if (self.state) |s| {
            s.forward = !s.forward;
        }
    }

    /// Check if animation is complete (not running and at end)
    pub fn isComplete(self: Self) bool {
        return !self.running and self.progress >= 1.0;
    }
};

// =============================================================================
// Progress Calculation (called by WidgetStore)
// =============================================================================

/// Calculate current progress for an animation state
pub fn calculateProgress(state: *AnimationState) AnimationHandle {
    if (!state.running) {
        // Stopped - return last position
        const final: f32 = if (state.forward) 1.0 else 0.0;
        return .{
            .progress = state.easing(final),
            .linear_progress = final,
            .running = false,
            .state = state,
        };
    }

    const now = platform.time.milliTimestamp();
    const elapsed = now - state.start_time;

    // Still in delay period
    if (elapsed < state.delay_ms) {
        return .{
            .progress = 0.0,
            .linear_progress = 0.0,
            .running = true,
            .state = state,
        };
    }

    const anim_elapsed = elapsed - @as(i64, @intCast(state.delay_ms));
    const duration: i64 = @intCast(state.duration_ms);

    if (duration == 0) {
        state.running = false;
        return .{
            .progress = 1.0,
            .linear_progress = 1.0,
            .running = false,
            .state = state,
        };
    }

    var t: f32 = @as(f32, @floatFromInt(anim_elapsed)) / @as(f32, @floatFromInt(duration));

    switch (state.mode) {
        .once => {
            if (t >= 1.0) {
                state.running = false;
                return .{
                    .progress = state.easing(1.0),
                    .linear_progress = 1.0,
                    .running = false,
                    .state = state,
                };
            }
        },
        .once_reset => {
            if (t >= 1.0) {
                state.running = false;
                return .{
                    .progress = 0.0,
                    .linear_progress = 0.0,
                    .running = false,
                    .state = state,
                };
            }
        },
        .loop => {
            t = @mod(t, 1.0);
        },
        .ping_pong => {
            const cycle: i32 = @intFromFloat(@floor(t));
            t = @mod(t, 1.0);
            // Reverse on odd cycles
            if (@mod(cycle, 2) == 1) {
                t = 1.0 - t;
            }
        },
    }

    return .{
        .progress = state.easing(t),
        .linear_progress = t,
        .running = true,
        .state = state,
    };
}

// =============================================================================
// Interpolation Utilities
// =============================================================================

/// Linear interpolation between two values
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Linear interpolation for integers
pub fn lerpInt(a: i32, b: i32, t: f32) i32 {
    return a + @as(i32, @intFromFloat(@as(f32, @floatFromInt(b - a)) * t));
}

/// Interpolate between two colors
pub fn lerpColor(a: Color, b: Color, t: f32) Color {
    return .{
        .r = lerp(a.r, b.r, t),
        .g = lerp(a.g, b.g, t),
        .b = lerp(a.b, b.b, t),
        .a = lerp(a.a, b.a, t),
    };
}

const Color = @import("../layout/types.zig").Color;

// =============================================================================
// Tests
// =============================================================================

test "easing functions produce valid output range" {
    const easings = [_]EasingFn{
        Easing.linear,
        Easing.easeIn,
        Easing.easeOut,
        Easing.easeInOut,
        Easing.easeOutCubic,
        Easing.bounce,
    };

    for (easings) |easing| {
        // Test endpoints
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), easing(0.0), 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), easing(1.0), 0.001);

        // Test monotonicity (value should generally increase)
        var prev: f32 = 0.0;
        var i: usize = 0;
        while (i <= 10) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / 10.0;
            const val = easing(t);
            // Allow small decreases for bounce
            try std.testing.expect(val >= prev - 0.3);
            prev = val;
        }
    }
}

test "easeOutBack can overshoot" {
    // easeOutBack should overshoot slightly
    const mid = Easing.easeOutBack(0.5);
    try std.testing.expect(mid > 0.5); // Should be ahead due to overshoot
}

test "lerp interpolates correctly" {
    try std.testing.expectEqual(@as(f32, 0.0), lerp(0.0, 100.0, 0.0));
    try std.testing.expectEqual(@as(f32, 50.0), lerp(0.0, 100.0, 0.5));
    try std.testing.expectEqual(@as(f32, 100.0), lerp(0.0, 100.0, 1.0));
    try std.testing.expectEqual(@as(f32, 25.0), lerp(0.0, 100.0, 0.25));
}

test "lerpInt interpolates correctly" {
    try std.testing.expectEqual(@as(i32, 0), lerpInt(0, 100, 0.0));
    try std.testing.expectEqual(@as(i32, 50), lerpInt(0, 100, 0.5));
    try std.testing.expectEqual(@as(i32, 100), lerpInt(0, 100, 1.0));
}

test "lerpColor interpolates correctly" {
    const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };

    const mid = lerpColor(black, white, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.g, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.b, 0.001);
}

test "AnimationState initializes correctly" {
    const state = AnimationState.init(.{ .duration_ms = 500 });
    try std.testing.expect(state.running);
    try std.testing.expectEqual(@as(u32, 500), state.duration_ms);
    try std.testing.expectEqual(@as(u32, 0), state.delay_ms);
    try std.testing.expect(state.forward);
}

test "AnimationConfig presets are valid" {
    try std.testing.expectEqual(@as(u32, 200), AnimationConfig.fade_in.duration_ms);
    try std.testing.expectEqual(@as(u32, 150), AnimationConfig.fade_out.duration_ms);
    try std.testing.expectEqual(@as(u32, 250), AnimationConfig.pop_in.duration_ms);
    try std.testing.expectEqual(AnimationConfig.Mode.once_reset, AnimationConfig.pulse.mode);
}
