//! Motion Containers — Lifecycle wrappers for enter/exit animations
//!
//! A motion container manages the enter/exit lifecycle so you never have to:
//! - Manually reverse progress on exit
//! - Keep rendering during exit animation
//! - Track show/hide transitions yourself
//!
//! Two flavors:
//! - **Tween-based** (`MotionConfig`): Fixed duration, easing curves. Predictable timing.
//!   NOTE: Tween motions restart from 0 on interruption (rapid toggle).
//! - **Spring-based** (`SpringMotionConfig`): Spring physics for enter/exit.
//!   Fully interruptible — velocity is preserved on direction change.
//!
//! Back-of-envelope:
//! - MotionState is ~200 bytes (2 AnimationState + 2 AnimationConfig + phase + bool).
//! - SpringMotionState is ~56 bytes (SpringState 48 + phase + bool + padding).
//! - Pool of MAX_MOTIONS (256) tween motions = ~50KB. Spring motions = ~14KB.
//! - Per-frame cost per active motion: one calculateProgress call or one RK4 step.
//!   At-rest motions cost one branch (early return). Zero work.

const std = @import("std");
const platform = @import("../platform/mod.zig");
const animation = @import("animation.zig");
const spring_mod = @import("spring.zig");

// =============================================================================
// Limits (per CLAUDE.md: "put a limit on everything")
// =============================================================================

/// Hard limit on simultaneous motion containers (tween or spring).
/// 256 tween motions × ~200B = ~50KB. 256 spring motions × ~56B = ~14KB.
pub const MAX_MOTIONS: u32 = 256;

// =============================================================================
// MotionPhase
// =============================================================================

pub const MotionPhase = enum {
    /// Enter animation is playing (progress going 0→1).
    entering,
    /// Fully entered and visible (progress = 1.0).
    entered,
    /// Exit animation is playing (progress going 1→0).
    exiting,
    /// Fully exited and invisible (progress = 0.0).
    exited,
};

// =============================================================================
// MotionConfig (tween-based)
// =============================================================================

/// Tween-based motion container configuration.
/// NOTE: Tween motions restart from progress=0 on interruption (rapid toggle).
/// For smooth interruptible enter/exit, use `SpringMotionConfig` instead.
pub const MotionConfig = struct {
    /// Tween config for the enter transition.
    enter: animation.AnimationConfig = .{
        .duration_ms = 250,
        .easing = animation.Easing.easeOutCubic,
    },

    /// Tween config for the exit transition.
    /// If null, uses enter config (symmetric).
    exit: ?animation.AnimationConfig = null,

    /// If true, start in the "entered" state (visible, progress=1) on first mount.
    /// If false (default), play the enter animation on first mount.
    start_visible: bool = false,

    // =========================================================================
    // Presets
    // =========================================================================

    /// Quick fade in/out.
    pub const fade = MotionConfig{
        .enter = .{ .duration_ms = 200 },
        .exit = .{ .duration_ms = 150, .easing = animation.Easing.easeIn },
    };

    /// Slide + fade.
    pub const slide = MotionConfig{
        .enter = .{ .duration_ms = 300, .easing = animation.Easing.easeOutCubic },
        .exit = .{ .duration_ms = 200, .easing = animation.Easing.easeIn },
    };

    /// Pop in with overshoot, quick fade out.
    pub const pop = MotionConfig{
        .enter = .{ .duration_ms = 250, .easing = animation.Easing.easeOutBack },
        .exit = .{ .duration_ms = 150, .easing = animation.Easing.easeIn },
    };

    /// Resolve the exit config: use explicit exit or fall back to enter (symmetric).
    fn exitConfig(self: MotionConfig) animation.AnimationConfig {
        return self.exit orelse self.enter;
    }
};

// =============================================================================
// SpringMotionConfig
// =============================================================================

/// Spring-based motion container configuration.
/// The spring drives both enter and exit — target is managed automatically.
pub const SpringMotionConfig = struct {
    /// Spring config for both enter and exit. Target is managed automatically.
    spring: spring_mod.SpringConfig = spring_mod.SpringConfig.default,

    /// If true, start in the "entered" state on first mount.
    start_visible: bool = false,

    pub const default = SpringMotionConfig{};
    pub const bouncy = SpringMotionConfig{ .spring = spring_mod.SpringConfig.bouncy };
    pub const snappy = SpringMotionConfig{ .spring = spring_mod.SpringConfig.snappy };
};

// =============================================================================
// MotionState (tween-based internal state)
// =============================================================================

pub const MotionState = struct {
    phase: MotionPhase,
    /// The last `show` value we saw. Used to detect transitions.
    last_show: bool,
    /// Tween-based: separate enter/exit animation states.
    /// Only one is active at a time.
    enter_state: animation.AnimationState,
    exit_state: animation.AnimationState,
    /// Stored configs — needed to reinitialize on re-entry/re-exit.
    enter_config: animation.AnimationConfig,
    exit_config: animation.AnimationConfig,
};

// =============================================================================
// SpringMotionState (spring-based internal state)
// =============================================================================

pub const SpringMotionState = struct {
    phase: MotionPhase,
    last_show: bool,
    spring_state: spring_mod.SpringState,
};

// =============================================================================
// MotionHandle (returned to user)
// =============================================================================

pub const MotionHandle = struct {
    /// Current progress: 0.0 (fully hidden) to 1.0 (fully visible).
    /// Goes 0→1 during enter, 1→0 during exit. Always in the "visibility" direction.
    progress: f32,

    /// Should the component be rendered? True during entering, entered, and exiting.
    /// False only in exited phase. Use this to gate rendering.
    visible: bool,

    /// Current lifecycle phase.
    phase: MotionPhase,

    const Self = @This();

    /// Fully hidden, don't render.
    pub const hidden = Self{ .progress = 0.0, .visible = false, .phase = .exited };

    /// Fully visible, settled.
    pub const shown = Self{ .progress = 1.0, .visible = true, .phase = .entered };
};

// =============================================================================
// Tick Logic — Tween-Based
// =============================================================================

/// Tick a tween-based motion container. Called by WidgetStore each frame.
///
/// State machine:
///   exited  --[show=true]--> entering --[complete]--> entered
///   entered --[show=false]--> exiting --[complete]--> exited
///
/// Progress goes 0→1 on enter, 1→0 on exit (reversed automatically).
pub fn tickMotion(state: *MotionState, show: bool) MotionHandle {
    std.debug.assert(state.enter_config.duration_ms > 0);
    std.debug.assert(state.exit_config.duration_ms > 0);

    // Detect show/hide transitions
    if (show != state.last_show) {
        state.last_show = show;
        if (show) {
            state.phase = .entering;
            state.enter_state = animation.AnimationState.init(state.enter_config);
        } else {
            state.phase = .exiting;
            state.exit_state = animation.AnimationState.init(state.exit_config);
        }
    }

    return switch (state.phase) {
        .entering => tickEntering(state),
        .entered => MotionHandle.shown,
        .exiting => tickExiting(state),
        .exited => MotionHandle.hidden,
    };
}

/// Handle the entering sub-state. Split out per 70-line rule.
fn tickEntering(state: *MotionState) MotionHandle {
    const handle = animation.calculateProgress(&state.enter_state);
    if (!handle.running) {
        state.phase = .entered;
        return MotionHandle.shown;
    }
    return .{
        .progress = handle.progress,
        .visible = true,
        .phase = .entering,
    };
}

/// Handle the exiting sub-state. Progress is reversed: exit goes 1→0.
fn tickExiting(state: *MotionState) MotionHandle {
    const handle = animation.calculateProgress(&state.exit_state);
    if (!handle.running) {
        state.phase = .exited;
        return MotionHandle.hidden;
    }
    return .{
        .progress = 1.0 - handle.progress,
        .visible = true,
        .phase = .exiting,
    };
}

// =============================================================================
// Tick Logic — Spring-Based
// =============================================================================

/// Tick a spring-based motion container.
///
/// The spring target is set to 1.0 (show) or 0.0 (hide) each frame.
/// Velocity is preserved on direction change — no snap, no restart.
/// Phase is derived from spring position and rest state.
pub fn tickSpringMotion(state: *SpringMotionState, show: bool) MotionHandle {
    std.debug.assert(state.spring_state.mass > 0.0);
    std.debug.assert(state.spring_state.stiffness >= 0.0);

    // Update target based on show state. The spring handles the rest.
    const target: f32 = if (show) 1.0 else 0.0;

    // Wake the spring if target changed (critical: at_rest springs skip physics
    // in tickSpring, so without this the animation never starts).
    const target_changed = state.spring_state.target != target;
    state.spring_state.target = target;
    state.last_show = show;

    if (target_changed and state.spring_state.at_rest) {
        state.spring_state.at_rest = false;
        // Reset timestamp so first dt after wake is reasonable
        state.spring_state.last_time_ms = platform.time.milliTimestamp();
    }

    const handle = spring_mod.tickSpring(&state.spring_state);

    // Derive phase from spring position and rest state
    if (handle.at_rest) {
        if (handle.value > 0.5) {
            state.phase = .entered;
            return MotionHandle.shown;
        } else {
            state.phase = .exited;
            return MotionHandle.hidden;
        }
    }

    // Spring is in flight — determine direction from show flag
    state.phase = if (show) .entering else .exiting;

    return .{
        .progress = std.math.clamp(handle.value, 0.0, 1.0),
        .visible = true,
        .phase = state.phase,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Helper: create a MotionState starting in the exited phase.
fn makeExitedState(config: MotionConfig) MotionState {
    const enter_config = config.enter;
    const exit_config = config.exitConfig();
    return .{
        .phase = .exited,
        .last_show = false,
        .enter_state = animation.AnimationState.initSettled(enter_config, 0),
        .exit_state = animation.AnimationState.initSettled(exit_config, 0),
        .enter_config = enter_config,
        .exit_config = exit_config,
    };
}

/// Helper: create a MotionState starting in the entered phase.
fn makeEnteredState(config: MotionConfig) MotionState {
    const enter_config = config.enter;
    const exit_config = config.exitConfig();
    return .{
        .phase = .entered,
        .last_show = true,
        .enter_state = animation.AnimationState.initSettled(enter_config, 0),
        .exit_state = animation.AnimationState.initSettled(exit_config, 0),
        .enter_config = enter_config,
        .exit_config = exit_config,
    };
}

/// Helper: create a SpringMotionState starting in the exited phase.
fn makeExitedSpringState(config: SpringMotionConfig) SpringMotionState {
    var spring_config = config.spring;
    spring_config.target = 0.0;
    spring_config.initial_position = 0.0;
    return .{
        .phase = .exited,
        .last_show = false,
        .spring_state = spring_mod.SpringState.initSettled(spring_config),
    };
}

test "tween motion: enter plays 0→1" {
    var state = makeExitedState(.{});

    // First frame with show=true triggers entering
    const h1 = tickMotion(&state, true);
    try testing.expect(h1.visible);
    try testing.expectEqual(MotionPhase.entering, h1.phase);
    try testing.expect(h1.progress >= 0.0);
    try testing.expect(h1.progress <= 1.0);
}

test "tween motion: exit plays 1→0" {
    var state = makeEnteredState(.{});

    // First frame with show=false triggers exiting
    const h1 = tickMotion(&state, false);
    try testing.expect(h1.visible); // Still visible during exit!
    try testing.expectEqual(MotionPhase.exiting, h1.phase);
    try testing.expect(h1.progress <= 1.0);
    try testing.expect(h1.progress >= 0.0);
}

test "tween motion: not visible after exit completes" {
    var state = makeEnteredState(.{
        .enter = .{ .duration_ms = 100 },
        .exit = .{ .duration_ms = 100 },
    });

    // Trigger exit
    _ = tickMotion(&state, false);
    try testing.expectEqual(MotionPhase.exiting, state.phase);

    // Simulate time passing: backdate the exit_state start_time
    // so calculateProgress sees the animation as complete.
    state.exit_state.start_time -= 200; // 200ms in the past, duration is 100ms

    const h = tickMotion(&state, false);
    try testing.expect(!h.visible);
    try testing.expectEqual(MotionPhase.exited, h.phase);
    try testing.expectApproxEqAbs(@as(f32, 0.0), h.progress, 0.001);
}

test "tween motion: not visible after enter then full exit" {
    var state = makeEnteredState(.{
        .enter = .{ .duration_ms = 50 },
        .exit = .{ .duration_ms = 50 },
    });

    // Trigger exit
    _ = tickMotion(&state, false);
    // Backdate to complete
    state.exit_state.start_time -= 100;
    const h = tickMotion(&state, false);
    try testing.expectEqual(MotionPhase.exited, h.phase);
    try testing.expect(!h.visible);
}

test "tween motion: enter completes to entered phase" {
    var state = makeExitedState(.{
        .enter = .{ .duration_ms = 50 },
    });

    // Trigger enter
    _ = tickMotion(&state, true);
    try testing.expectEqual(MotionPhase.entering, state.phase);

    // Backdate to complete
    state.enter_state.start_time -= 100;
    const h = tickMotion(&state, true);
    try testing.expectEqual(MotionPhase.entered, h.phase);
    try testing.expect(h.visible);
    try testing.expectApproxEqAbs(@as(f32, 1.0), h.progress, 0.001);
}

test "tween motion: re-enter during exit restarts enter" {
    var state = makeEnteredState(.{
        .enter = .{ .duration_ms = 200 },
        .exit = .{ .duration_ms = 200 },
    });

    // Start exiting
    _ = tickMotion(&state, false);
    try testing.expectEqual(MotionPhase.exiting, state.phase);

    // Immediately toggle back to show
    const h = tickMotion(&state, true);
    try testing.expectEqual(MotionPhase.entering, h.phase);
    try testing.expect(h.visible);
}

test "tween motion: entered state is stable" {
    var state = makeEnteredState(.{});

    // Multiple ticks with show=true should stay entered
    const h1 = tickMotion(&state, true);
    const h2 = tickMotion(&state, true);
    try testing.expectEqual(MotionPhase.entered, h1.phase);
    try testing.expectEqual(MotionPhase.entered, h2.phase);
    try testing.expectApproxEqAbs(@as(f32, 1.0), h1.progress, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), h2.progress, 0.001);
}

test "tween motion: exited state is stable" {
    var state = makeExitedState(.{});

    // Multiple ticks with show=false should stay exited
    const h1 = tickMotion(&state, false);
    const h2 = tickMotion(&state, false);
    try testing.expectEqual(MotionPhase.exited, h1.phase);
    try testing.expectEqual(MotionPhase.exited, h2.phase);
    try testing.expect(!h1.visible);
    try testing.expect(!h2.visible);
}

test "tween motion: exit config defaults to enter when null" {
    const config = MotionConfig{ .enter = .{ .duration_ms = 300 } };
    const exit = config.exitConfig();
    try testing.expectEqual(@as(u32, 300), exit.duration_ms);
}

test "tween motion: exit config uses explicit exit when set" {
    const config = MotionConfig{
        .enter = .{ .duration_ms = 300 },
        .exit = .{ .duration_ms = 150 },
    };
    const exit = config.exitConfig();
    try testing.expectEqual(@as(u32, 150), exit.duration_ms);
}

test "spring motion: enter from exited" {
    var state = makeExitedSpringState(.{});

    // Tick with show=true — spring wakes from rest and starts entering
    const h = tickSpringMotion(&state, true);
    // With the wake-from-rest fix, the spring reliably enters on the first tick
    try testing.expectEqual(MotionPhase.entering, h.phase);
    try testing.expect(h.visible);
}

test "spring motion: wake from rest on toggle" {
    // Start settled at 0 (exited, at rest)
    var state = makeExitedSpringState(.{});
    try testing.expect(state.spring_state.at_rest);
    try testing.expectApproxEqAbs(@as(f32, 0.0), state.spring_state.position, 0.001);

    // Toggle show=true — spring must wake and begin entering
    const h1 = tickSpringMotion(&state, true);
    try testing.expect(!state.spring_state.at_rest);
    try testing.expectEqual(MotionPhase.entering, h1.phase);
    try testing.expect(h1.visible);

    // Manually settle the spring at 1.0 (simulate fully entered)
    state.spring_state.position = 1.0;
    state.spring_state.velocity = 0.0;
    state.spring_state.target = 1.0;
    state.spring_state.at_rest = true;
    state.phase = .entered;

    // Toggle show=false — spring must wake and begin exiting
    const h2 = tickSpringMotion(&state, false);
    try testing.expect(!state.spring_state.at_rest);
    try testing.expectEqual(MotionPhase.exiting, h2.phase);
    try testing.expect(h2.visible);
    try testing.expect(h2.progress > 0.0);
}

test "spring motion: rapid toggle doesn't snap" {
    // Create a spring motion that's already partway through entering
    var state = SpringMotionState{
        .phase = .entering,
        .last_show = true,
        .spring_state = spring_mod.SpringState.init(.{
            .target = 1.0,
            .initial_position = 0.0,
        }),
    };

    // Manually advance the spring to a midpoint position
    state.spring_state.position = 0.5;
    state.spring_state.velocity = 2.0;
    state.spring_state.at_rest = false;
    state.spring_state.last_time_ms = platform.time.milliTimestamp();

    // Toggle off — spring should redirect, not snap
    const h = tickSpringMotion(&state, false);

    // Should be visible (exit in progress) and progress > 0
    try testing.expect(h.visible);
    try testing.expect(h.progress > 0.0);
    try testing.expectEqual(MotionPhase.exiting, h.phase);
}

test "spring motion: settled at target 1.0 is entered" {
    var state = SpringMotionState{
        .phase = .entering,
        .last_show = true,
        .spring_state = spring_mod.SpringState.initSettled(.{
            .target = 1.0,
        }),
    };

    const h = tickSpringMotion(&state, true);
    try testing.expectEqual(MotionPhase.entered, h.phase);
    try testing.expect(h.visible);
    try testing.expectApproxEqAbs(@as(f32, 1.0), h.progress, 0.001);
}

test "spring motion: settled at target 0.0 is exited" {
    var state = SpringMotionState{
        .phase = .exiting,
        .last_show = false,
        .spring_state = spring_mod.SpringState.initSettled(.{
            .target = 0.0,
            .initial_position = 0.0,
        }),
    };

    const h = tickSpringMotion(&state, false);
    try testing.expectEqual(MotionPhase.exited, h.phase);
    try testing.expect(!h.visible);
    try testing.expectApproxEqAbs(@as(f32, 0.0), h.progress, 0.001);
}

test "motion handle constants are correct" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), MotionHandle.hidden.progress, 0.001);
    try testing.expect(!MotionHandle.hidden.visible);
    try testing.expectEqual(MotionPhase.exited, MotionHandle.hidden.phase);

    try testing.expectApproxEqAbs(@as(f32, 1.0), MotionHandle.shown.progress, 0.001);
    try testing.expect(MotionHandle.shown.visible);
    try testing.expectEqual(MotionPhase.entered, MotionHandle.shown.phase);
}

test "motion config presets have valid durations" {
    const presets = [_]MotionConfig{
        MotionConfig.fade,
        MotionConfig.slide,
        MotionConfig.pop,
    };
    for (presets) |preset| {
        try testing.expect(preset.enter.duration_ms > 0);
        const exit = preset.exitConfig();
        try testing.expect(exit.duration_ms > 0);
    }
}

test "spring motion config presets have valid spring params" {
    const presets = [_]SpringMotionConfig{
        SpringMotionConfig.default,
        SpringMotionConfig.bouncy,
        SpringMotionConfig.snappy,
    };
    for (presets) |preset| {
        try testing.expect(preset.spring.stiffness > 0.0);
        try testing.expect(preset.spring.damping > 0.0);
        try testing.expect(preset.spring.mass > 0.0);
    }
}

test "motion phase enum has exactly 4 variants" {
    // Compile-time check: all phases are covered
    const phases = [_]MotionPhase{ .entering, .entered, .exiting, .exited };
    try testing.expectEqual(@as(usize, 4), phases.len);
}
