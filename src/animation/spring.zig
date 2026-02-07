//! Spring Physics Animation
//!
//! Stateful spring simulation using RK4 (4th-order Runge-Kutta) integration.
//! Springs have position and velocity — when the target changes, the spring
//! inherits its current state and smoothly redirects. No restart, no snap.
//!
//! RK4 is used instead of Euler because Euler is unstable at UI timesteps
//! (16ms frames at stiffness=300 show visible energy gain; dropped frames
//! at 32ms+ cause springs to oscillate forever). RK4 evaluates the derivative
//! at four points per step, producing a weighted average that is stable for
//! all reasonable stiffness/damping values at one step per frame.
//!
//! Back-of-envelope:
//! - SpringState is ~48 bytes (8 floats + 1 i64 + 1 bool + padding).
//! - Pool of MAX_SPRINGS (256) = ~12KB. Pre-allocatable.
//! - Per-frame cost per active spring: one RK4 step = ~20 multiply-adds.
//!   At 256 springs that's ~5,000 FLOPs — invisible next to GPU work.
//! - At-rest springs cost one branch (early return in tickSpring). Zero physics.

const std = @import("std");
const platform = @import("../platform/mod.zig");

// =============================================================================
// Limits (per CLAUDE.md: "put a limit on everything")
// =============================================================================

/// Hard limit on simultaneous springs.
/// 256 springs * ~48 bytes = ~12KB. Typical UI: 5–20 springs.
pub const MAX_SPRINGS: u32 = 256;

/// Springs closer than this to target with velocity below this are considered at rest.
const DEFAULT_REST_THRESHOLD: f32 = 0.0005;

/// Maximum delta-time per step in seconds. Prevents instability on long frame drops.
/// If real dt exceeds this, we clamp rather than subdivide (simpler, predictable).
const MAX_DT: f32 = 0.064; // ~15fps floor

// =============================================================================
// SpringConfig
// =============================================================================

pub const SpringConfig = struct {
    /// Target value the spring moves toward. Declarative — set every frame.
    target: f32 = 1.0,

    /// Spring constant (tension). Higher = faster, snappier motion.
    /// Typical range: 80–400.
    stiffness: f32 = 170.0,

    /// Friction coefficient. Higher = less oscillation.
    /// Critical damping ≈ 2 * sqrt(stiffness * mass).
    /// Typical range: 10–40.
    damping: f32 = 26.0,

    /// Mass of the animated object. Higher = more sluggish, more momentum.
    /// Almost always 1.0. Increase for heavy/deliberate feel.
    mass: f32 = 1.0,

    /// Position + velocity below this threshold = at rest. Defaults to 0.0005.
    rest_threshold: f32 = DEFAULT_REST_THRESHOLD,

    /// Initial position when the spring is first created. Defaults to 0.0.
    /// Set to target value if you want the spring to start settled.
    initial_position: f32 = 0.0,

    // =========================================================================
    // Presets
    // =========================================================================

    /// Default — slightly bouncy, settles quickly. Good for modals, toggles.
    pub const default: SpringConfig = .{};

    /// No bounce, fast settle. Good for opacity, color transitions.
    pub const snappy: SpringConfig = .{ .stiffness = 300, .damping = 30 };

    /// Visible bounce. Good for pop-in effects, attention-grabbing.
    pub const bouncy: SpringConfig = .{ .stiffness = 180, .damping = 12 };

    /// Slow, smooth. Good for background transitions, ambient motion.
    pub const gentle: SpringConfig = .{ .stiffness = 120, .damping = 20 };

    /// Very fast, no bounce. Good for micro-interactions, hover states.
    pub const stiff: SpringConfig = .{ .stiffness = 400, .damping = 40 };

    /// Wobbly — low damping, visible oscillation. Good for playful UI.
    pub const wobbly: SpringConfig = .{ .stiffness = 150, .damping = 8 };
};

// =============================================================================
// SpringState
// =============================================================================

pub const SpringState = struct {
    position: f32,
    velocity: f32,
    target: f32,
    stiffness: f32,
    damping: f32,
    mass: f32,
    rest_threshold: f32,
    at_rest: bool,
    last_time_ms: i64,

    const Self = @This();

    pub fn init(config: SpringConfig) Self {
        const now = platform.time.milliTimestamp();
        std.debug.assert(config.mass > 0.0);
        std.debug.assert(config.stiffness >= 0.0);
        return .{
            .position = config.initial_position,
            .velocity = 0.0,
            .target = config.target,
            .stiffness = config.stiffness,
            .damping = config.damping,
            .mass = config.mass,
            .rest_threshold = config.rest_threshold,
            .at_rest = (config.initial_position == config.target),
            .last_time_ms = now,
        };
    }

    /// Initialize in a settled state (at target, zero velocity, at rest).
    pub fn initSettled(config: SpringConfig) Self {
        const now = platform.time.milliTimestamp();
        std.debug.assert(config.mass > 0.0);
        std.debug.assert(config.stiffness >= 0.0);
        return .{
            .position = config.target,
            .velocity = 0.0,
            .target = config.target,
            .stiffness = config.stiffness,
            .damping = config.damping,
            .mass = config.mass,
            .rest_threshold = config.rest_threshold,
            .at_rest = true,
            .last_time_ms = now,
        };
    }
};

// =============================================================================
// SpringHandle
// =============================================================================

pub const SpringHandle = struct {
    /// Current spring position. Can overshoot past 0.0 or 1.0 for bouncy springs.
    value: f32,

    /// Current velocity. Useful for gesture handoff or chained springs.
    velocity: f32,

    /// True when the spring has settled at its target (within rest_threshold).
    at_rest: bool,

    /// Back-pointer for imperative control. Null if spring doesn't exist (hit pool limit).
    state: ?*SpringState,

    const Self = @This();

    /// A settled spring at position 0.
    pub const zero: Self = .{ .value = 0.0, .velocity = 0.0, .at_rest = true, .state = null };

    /// A settled spring at position 1.
    pub const one: Self = .{ .value = 1.0, .velocity = 0.0, .at_rest = true, .state = null };

    /// Clamp value to 0.0–1.0. Useful when you need bounded progress
    /// (e.g., opacity) but the spring can overshoot.
    pub fn clamped(self: Self) f32 {
        return std.math.clamp(self.value, 0.0, 1.0);
    }

    /// Nudge the spring with an impulse velocity. Useful for gesture release.
    pub fn impulse(self: Self, added_velocity: f32) void {
        if (self.state) |s| {
            s.velocity += added_velocity;
            s.at_rest = false;
        }
    }
};

// =============================================================================
// RK4 Integration
// =============================================================================

/// Compute spring acceleration from current state.
/// F = -k * displacement - c * velocity; a = F / m
fn acceleration(pos: f32, vel: f32, target: f32, k: f32, c: f32, m: f32) f32 {
    std.debug.assert(m > 0.0);
    std.debug.assert(k >= 0.0);
    return (-(k) * (pos - target) - c * vel) / m;
}

/// Advance spring state by dt seconds using RK4 integration.
/// Mutates state.position, state.velocity, state.at_rest.
pub fn stepSpring(state: *SpringState, dt_raw: f32) void {
    std.debug.assert(dt_raw >= 0.0);
    std.debug.assert(state.mass > 0.0);

    // Clamp dt to prevent instability on long frame drops
    const dt = @min(dt_raw, MAX_DT);
    if (dt <= 0.0) return;

    const p = state.position;
    const v = state.velocity;
    const target = state.target;
    const k = state.stiffness;
    const c = state.damping;
    const m = state.mass;

    // RK4: four evaluations of acceleration
    //
    // k1: slope at start
    const a1 = acceleration(p, v, target, k, c, m);
    const v1 = v;

    // k2: slope at midpoint using k1
    const p2 = p + v1 * (dt * 0.5);
    const v2 = v + a1 * (dt * 0.5);
    const a2 = acceleration(p2, v2, target, k, c, m);

    // k3: slope at midpoint using k2
    const p3 = p + v2 * (dt * 0.5);
    const v3 = v + a2 * (dt * 0.5);
    const a3 = acceleration(p3, v3, target, k, c, m);

    // k4: slope at endpoint using k3
    const p4 = p + v3 * dt;
    const v4 = v + a3 * dt;
    const a4 = acceleration(p4, v4, target, k, c, m);

    // Weighted average
    state.position = p + (dt / 6.0) * (v1 + 2.0 * v2 + 2.0 * v3 + v4);
    state.velocity = v + (dt / 6.0) * (a1 + 2.0 * a2 + 2.0 * a3 + a4);

    // Rest detection
    const dist = @abs(state.position - target);
    const speed = @abs(state.velocity);
    if (dist < state.rest_threshold and speed < state.rest_threshold) {
        state.position = target;
        state.velocity = 0.0;
        state.at_rest = true;
    } else {
        state.at_rest = false;
    }
}

/// Tick a spring: compute dt from wall clock, step physics, return handle.
pub fn tickSpring(state: *SpringState) SpringHandle {
    if (state.at_rest) {
        return .{
            .value = state.position,
            .velocity = 0.0,
            .at_rest = true,
            .state = state,
        };
    }

    const now = platform.time.milliTimestamp();
    const elapsed_ms = now - state.last_time_ms;
    state.last_time_ms = now;

    // Convert to seconds for physics
    const dt: f32 = @as(f32, @floatFromInt(@max(elapsed_ms, 0))) / 1000.0;
    stepSpring(state, dt);

    return .{
        .value = state.position,
        .velocity = state.velocity,
        .at_rest = state.at_rest,
        .state = state,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "spring reaches target" {
    var state = SpringState.init(.{ .target = 1.0, .initial_position = 0.0 });
    // Simulate 2 seconds at 60fps
    var i: u32 = 0;
    while (i < 120) : (i += 1) {
        stepSpring(&state, 1.0 / 60.0);
    }
    try std.testing.expect(state.at_rest);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.position, 0.001);
}

test "spring inherits velocity on target change" {
    var state = SpringState.init(.{
        .target = 1.0,
        .initial_position = 0.0,
        .stiffness = 200,
        .damping = 10,
    });
    // Advance 10 frames — spring is in flight
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        stepSpring(&state, 1.0 / 60.0);
    }
    const velocity_before = state.velocity;
    try std.testing.expect(velocity_before > 0.0);
    try std.testing.expect(!state.at_rest);

    // Reverse target mid-flight
    state.target = 0.0;
    stepSpring(&state, 1.0 / 60.0);

    // Velocity is still positive (momentum carries forward briefly)
    try std.testing.expect(state.velocity > 0.0);
}

test "spring at rest produces zero cost" {
    var state = SpringState.initSettled(.{ .target = 1.0 });
    try std.testing.expect(state.at_rest);
    const handle = tickSpring(&state);
    try std.testing.expect(handle.at_rest);
    try std.testing.expectEqual(@as(f32, 1.0), handle.value);
}

test "bouncy spring overshoots" {
    var state = SpringState.init(.{
        .target = 1.0,
        .initial_position = 0.0,
        .stiffness = 180,
        .damping = 8, // Low damping = overshoot
    });
    var max_pos: f32 = 0.0;
    var i: u32 = 0;
    while (i < 120) : (i += 1) {
        stepSpring(&state, 1.0 / 60.0);
        if (state.position > max_pos) max_pos = state.position;
    }
    // Should have overshot past 1.0 at some point
    try std.testing.expect(max_pos > 1.0);
    // But should have settled at target
    try std.testing.expect(state.at_rest);
}

test "rk4 is stable at large timestep" {
    // Euler would blow up here. RK4 should be fine.
    var state = SpringState.init(.{
        .target = 1.0,
        .initial_position = 0.0,
        .stiffness = 300,
        .damping = 15,
    });
    // Simulate long frame drops: 50ms steps
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        stepSpring(&state, 0.05);
    }
    // Should converge, not explode
    try std.testing.expect(@abs(state.position - 1.0) < 0.01);
}

test "spring config presets have valid parameters" {
    const presets = [_]SpringConfig{
        SpringConfig.default,
        SpringConfig.snappy,
        SpringConfig.bouncy,
        SpringConfig.gentle,
        SpringConfig.stiff,
        SpringConfig.wobbly,
    };
    for (presets) |preset| {
        try std.testing.expect(preset.stiffness > 0.0);
        try std.testing.expect(preset.damping > 0.0);
        try std.testing.expect(preset.mass > 0.0);
        try std.testing.expect(preset.rest_threshold > 0.0);
    }
}

test "spring handle clamped bounds overshoot" {
    const handle = SpringHandle{
        .value = 1.3,
        .velocity = 2.0,
        .at_rest = false,
        .state = null,
    };
    try std.testing.expectEqual(@as(f32, 1.0), handle.clamped());

    const handle_under = SpringHandle{
        .value = -0.2,
        .velocity = -1.0,
        .at_rest = false,
        .state = null,
    };
    try std.testing.expectEqual(@as(f32, 0.0), handle_under.clamped());
}

test "step with zero dt is a no-op" {
    var state = SpringState.init(.{ .target = 1.0, .initial_position = 0.0 });
    const pos_before = state.position;
    const vel_before = state.velocity;
    stepSpring(&state, 0.0);
    try std.testing.expectEqual(pos_before, state.position);
    try std.testing.expectEqual(vel_before, state.velocity);
}

test "spring settles from target to zero" {
    var state = SpringState.init(.{
        .target = 0.0,
        .initial_position = 1.0,
    });
    var i: u32 = 0;
    while (i < 120) : (i += 1) {
        stepSpring(&state, 1.0 / 60.0);
    }
    try std.testing.expect(state.at_rest);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), state.position, 0.001);
}

test "large dt is clamped to MAX_DT" {
    var state = SpringState.init(.{
        .target = 1.0,
        .initial_position = 0.0,
        .stiffness = 300,
        .damping = 20,
    });
    // A huge dt (1 second) should be clamped and not explode
    stepSpring(&state, 1.0);
    try std.testing.expect(!std.math.isNan(state.position));
    try std.testing.expect(!std.math.isInf(state.position));
    try std.testing.expect(!std.math.isNan(state.velocity));
    try std.testing.expect(!std.math.isInf(state.velocity));
}
