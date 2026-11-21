const std = @import("std");
const cx_mod = @import("cx.zig");
const id_mod = @import("id.zig");
const window_mod = @import("window.zig");

const assert = std.debug.assert;
const Cx = cx_mod.Cx;
const Key = id_mod.Key;

pub const tween_duration_ms_max: u32 = 60_000;

pub const loop_period_ms_max: u32 = 60_000;

/// The longest step a spring integrates; longer gaps are clamped to keep RK4 stable.
const spring_step_s_max: f32 = 0.064;

/// A spring closer than this to its target, and slower than this, is at rest.
const spring_rest_threshold: f32 = 0.0005;

/// Easing curves: every curve maps 0 to 0 and 1 to 1; `easeOutBack` overshoots 1 on the way.
pub const Easing = struct {
    pub fn linear(t: f32) f32 {
        return t;
    }

    pub fn easeIn(t: f32) f32 {
        return t * t;
    }

    pub fn easeOut(t: f32) f32 {
        return 1.0 - (1.0 - t) * (1.0 - t);
    }

    pub fn easeInOut(t: f32) f32 {
        if (t < 0.5) return 2.0 * t * t;
        const x = -2.0 * t + 2.0;
        return 1.0 - x * x / 2.0;
    }

    pub fn easeOutCubic(t: f32) f32 {
        const x = 1.0 - t;
        return 1.0 - x * x * x;
    }

    pub fn easeOutBack(t: f32) f32 {
        const c1: f32 = 1.70158;
        const c3: f32 = c1 + 1.0;
        const x = t - 1.0;
        return 1.0 + c3 * x * x * x + c1 * x * x;
    }
};

pub const Tween = struct {
    duration_ms: u32 = 200,
    /// Time at 0 before the tween moves.
    delay_ms: u32 = 0,
    easing: *const fn (t: f32) f32 = Easing.easeOut,
};

/// Mass is 1, so stiffness and damping are per unit mass; critical damping is 2·√stiffness.
pub const Spring = struct {
    stiffness: f32 = 170,
    damping: f32 = 26,

    pub const snappy: Spring = .{ .stiffness = 300, .damping = 30 };
    pub const bouncy: Spring = .{ .stiffness = 180, .damping = 12 };
    pub const gentle: Spring = .{ .stiffness = 120, .damping = 20 };
    pub const stiff: Spring = .{ .stiffness = 400, .damping = 40 };
    pub const wobbly: Spring = .{ .stiffness = 150, .damping = 8 };
};

pub const Phase = enum { entering, entered, exiting, exited };

/// `progress` runs 0 → 1 while entering and 1 → 0 while exiting; build the
/// element only while `visible`.
pub const Motion = struct {
    progress: f32,
    visible: bool,
    phase: Phase,

    pub const shown: Motion = .{ .progress = 1, .visible = true, .phase = .entered };
    pub const hidden: Motion = .{ .progress = 0, .visible = false, .phase = .exited };
};

const TweenState = struct {
    start_ns: u64,
    trigger: u64,
    /// The last build that read this tween, to tell when it returns.
    built_frame: u64,
    started: bool,
    finished: bool,

    fn init(state: *TweenState) void {
        state.* = .{
            .start_ns = 0,
            .trigger = 0,
            .built_frame = 0,
            .started = false,
            .finished = false,
        };
    }

    fn restart(state: *TweenState, now_ns: u64) void {
        state.start_ns = now_ns;
        state.started = true;
        state.finished = false;
    }
};

const MotionState = struct {
    position: f32,
    velocity: f32,
    target: f32,
    stepped_ns: u64,
    at_rest: bool,

    fn init(state: *MotionState) void {
        state.* = .{
            .position = 0,
            .velocity = 0,
            .target = 0,
            .stepped_ns = 0,
            .at_rest = true,
        };
    }
};

const LoopState = struct {
    start_ns: u64,
    /// The last build that read this loop, to tell when it returns.
    built_frame: u64,
    started: bool,

    fn init(state: *LoopState) void {
        state.* = .{ .start_ns = 0, .built_frame = 0, .started = false };
    }
};

comptime {
    assert(@sizeOf(LoopState) <= 64);
    assert(@sizeOf(TweenState) <= 64);
    assert(@sizeOf(MotionState) <= 64);
}

/// The phase of the loop keyed `key` under the box being built: time since
/// its first build, modulo `period_ms`, as a fraction in [0, 1). Every build
/// that reads it requests a frame; a build that skips it requests none. A
/// loop that the previous build did not read starts again from 0.
pub fn loop(cx: *Cx, key: Key, period_ms: u32) f32 {
    assert(period_ms > 0);
    assert(period_ms <= loop_period_ms_max);
    const window = cx_mod.windowOf(cx);
    const now_ns = cx.now();
    const state = cx.get(LoopState, cx.retain(LoopState, cx.id(key), .frame, LoopState.init));
    const returning = state.built_frame + 1 < window.frame_number;
    if (!state.started or returning) {
        state.start_ns = now_ns;
        state.started = true;
    }
    state.built_frame = window.frame_number;
    assert(now_ns >= state.start_ns);
    const period_ns = @as(u64, period_ms) * std.time.ns_per_ms;
    const offset_ns = (now_ns - state.start_ns) % period_ns;
    const phase: f64 = @as(f64, @floatFromInt(offset_ns)) / @as(f64, @floatFromInt(period_ns));
    // An offset within one f32 step of the period rounds to 1: that is the wrap.
    const phase_f32: f32 = @floatCast(phase);
    const result: f32 = if (phase_f32 < 1) phase_f32 else 0;
    assert(result >= 0);
    assert(result < 1);
    cx.requestRenderAfter(0);
    return result;
}

/// The eased progress of the tween keyed `key` under the box being built: 0
/// from its first build through `delay_ms`, then along `easing` to 1 after
/// `duration_ms`. A finished tween that the previous build did not read
/// plays again, so an element that leaves and returns replays its entrance.
pub fn tween(cx: *Cx, key: Key, options: Tween) f32 {
    checkTween(options);
    const window = cx_mod.windowOf(cx);
    const state = cx.get(TweenState, cx.retain(TweenState, cx.id(key), .frame, TweenState.init));
    const returning = state.built_frame + 1 < window.frame_number;
    if (!state.started) {
        state.restart(window.now_ns);
    } else {
        if (state.finished and returning) state.restart(window.now_ns);
    }
    state.built_frame = window.frame_number;
    return advance(cx, state, options);
}

/// The eased progress of a tween that starts finished, at 1, and plays from
/// 0 again in each build whose `trigger` differs from the last one's.
pub fn tweenOn(cx: *Cx, key: Key, trigger: u64, options: Tween) f32 {
    checkTween(options);
    const window = cx_mod.windowOf(cx);
    const state = cx.get(TweenState, cx.retain(TweenState, cx.id(key), .frame, TweenState.init));
    if (!state.started) {
        state.restart(window.now_ns);
        state.finished = true;
        state.trigger = trigger;
    } else {
        if (state.trigger != trigger) {
            state.trigger = trigger;
            state.restart(window.now_ns);
        }
    }
    state.built_frame = window.frame_number;
    return advance(cx, state, options);
}

fn checkTween(options: Tween) void {
    assert(options.duration_ms <= tween_duration_ms_max);
    assert(options.delay_ms <= window_mod.render_delay_ms_max);
}

fn advance(cx: *Cx, state: *TweenState, options: Tween) f32 {
    assert(state.started);
    if (state.finished) return options.easing(1);
    const now_ns = cx.now();
    assert(now_ns >= state.start_ns);
    const elapsed_ns = now_ns - state.start_ns;
    const delay_ns = @as(u64, options.delay_ms) * std.time.ns_per_ms;
    if (elapsed_ns < delay_ns) {
        // Nothing moves until the delay ends, so no frame is due before it.
        const remaining_ms = std.math.divCeil(u64, delay_ns - elapsed_ns, std.time.ns_per_ms) catch
            unreachable; // The divisor is a nonzero constant.
        assert(remaining_ms <= options.delay_ms);
        cx.requestRenderAfter(@intCast(remaining_ms));
        return 0;
    }
    const duration_ns = @as(u64, options.duration_ms) * std.time.ns_per_ms;
    if (elapsed_ns - delay_ns >= duration_ns) {
        state.finished = true;
        return options.easing(1);
    }
    const t = @as(f32, @floatFromInt(elapsed_ns - delay_ns)) / @as(f32, @floatFromInt(duration_ns));
    assert(t >= 0);
    assert(t < 1);
    cx.requestRenderAfter(0);
    return options.easing(t);
}

/// An interruptible enter and exit for the element keyed `key`: a spring
/// toward 1 while `show` and toward 0 otherwise, keeping its velocity when
/// `show` flips mid-flight. Shown at the first build, it enters from 0.
pub fn motion(cx: *Cx, key: Key, show: bool, spring: Spring) Motion {
    assert(spring.stiffness > 0);
    assert(spring.damping >= 0);
    const now_ns = cx.now();
    const state = cx.get(MotionState, cx.retain(MotionState, cx.id(key), .frame, MotionState.init));
    const target: f32 = if (show) 1 else 0;
    if (state.target != target) {
        state.target = target;
        // A spring at rest skips the step, so a new target wakes it; one in
        // flight keeps its velocity and clock.
        if (state.at_rest) {
            state.at_rest = false;
            state.stepped_ns = now_ns;
        }
    }
    if (!state.at_rest) stepMotion(state, spring, now_ns);
    if (state.at_rest) {
        assert(state.position == target);
        return if (show) Motion.shown else Motion.hidden;
    }
    cx.requestRenderAfter(0);
    return .{
        .progress = std.math.clamp(state.position, 0, 1),
        .visible = true,
        .phase = if (show) .entering else .exiting,
    };
}

/// Advance the spring to `now_ns` and settle it on its target once it is
/// within the rest threshold in both position and speed.
fn stepMotion(state: *MotionState, spring: Spring, now_ns: u64) void {
    assert(!state.at_rest);
    assert(now_ns >= state.stepped_ns);
    const elapsed_s = @as(f32, @floatFromInt(now_ns - state.stepped_ns)) / std.time.ns_per_s;
    state.stepped_ns = now_ns;
    const body = stepSpring(.{
        .position = state.position,
        .velocity = state.velocity,
    }, state.target, spring, @min(elapsed_s, spring_step_s_max));
    state.position = body.position;
    state.velocity = body.velocity;
    const distance = @abs(state.position - state.target);
    if (distance < spring_rest_threshold and @abs(state.velocity) < spring_rest_threshold) {
        state.position = state.target;
        state.velocity = 0;
        state.at_rest = true;
    }
}

const Body = struct { position: f32, velocity: f32 };

/// One RK4 step of a unit-mass damped spring over `dt_s` seconds.
fn stepSpring(body: Body, target: f32, spring: Spring, dt_s: f32) Body {
    assert(dt_s >= 0);
    assert(dt_s <= spring_step_s_max);
    const half = dt_s * 0.5;
    const a1 = acceleration(body.position, body.velocity, target, spring);
    const v1 = body.velocity;
    const v2 = body.velocity + a1 * half;
    const a2 = acceleration(body.position + v1 * half, v2, target, spring);
    const v3 = body.velocity + a2 * half;
    const a3 = acceleration(body.position + v2 * half, v3, target, spring);
    const v4 = body.velocity + a3 * dt_s;
    const a4 = acceleration(body.position + v3 * dt_s, v4, target, spring);
    return .{
        .position = body.position + (dt_s / 6.0) * (v1 + 2.0 * v2 + 2.0 * v3 + v4),
        .velocity = body.velocity + (dt_s / 6.0) * (a1 + 2.0 * a2 + 2.0 * a3 + a4),
    };
}

fn acceleration(position: f32, velocity: f32, target: f32, spring: Spring) f32 {
    return -spring.stiffness * (position - target) - spring.damping * velocity;
}

test "easing curves map 0 to 0 and 1 to 1, and easeOutBack overshoots" {
    const names = .{ "linear", "easeIn", "easeOut", "easeInOut", "easeOutCubic", "easeOutBack" };
    inline for (names) |name| {
        const curve = @field(Easing, name);
        try std.testing.expectApproxEqAbs(@as(f32, 0), curve(0), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1), curve(1), 1e-6);
    }
    try std.testing.expect(Easing.easeOutBack(0.6) > 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), Easing.easeInOut(0.5), 1e-6);
}

test "a spring settles on its target and keeps its velocity when the target flips" {
    var body: Body = .{ .position = 0, .velocity = 0 };
    for (0..6) |_| body = stepSpring(body, 1, .snappy, 1.0 / 60.0);
    try std.testing.expect(body.velocity > 0);
    const before = body.velocity;
    body = stepSpring(body, 0, .snappy, 1.0 / 60.0);
    try std.testing.expect(body.velocity < before);
    try std.testing.expect(body.position > 0);
    for (0..120) |_| body = stepSpring(body, 0, .snappy, 1.0 / 60.0);
    try std.testing.expect(@abs(body.position) < spring_rest_threshold);
    try std.testing.expect(@abs(body.velocity) < spring_rest_threshold);
}
