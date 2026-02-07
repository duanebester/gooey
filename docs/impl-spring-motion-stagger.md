# Animation System Improvements: Spring Physics, Motion Containers, Stagger

**Status:** In Progress  
**Scope:** `src/animation/`, `src/context/widget_store.zig`, `src/context/gooey.zig`, `src/cx.zig`, `src/root.zig`

---

## Motivation

Gooey's animation system is time-based tweens: a progress value goes from 0→1 over a fixed duration with an easing curve. This works for fire-and-forget transitions but breaks down in three scenarios:

1. **Interruption.** If a user toggles a panel rapidly, `animateOn` restarts the tween from 0. The panel snaps back and begins a fresh 400ms ease-out. There is no concept of "current velocity" to inherit.

2. **Enter/exit lifecycle.** The `PanelSection` pattern in `src/examples/animation.zig` requires manual bookkeeping: `if (self.show or slide.running)`, manual progress reversal `if (self.show) slide.progress else 1.0 - slide.progress`, and remembering `initSettled` semantics. Every component with show/hide repeats this.

3. **List choreography.** Animating list items with staggered entry requires manual delay computation per item. There's no built-in way to express "items cascade in 50ms apart, from the top."

These three features — springs, motion containers, stagger — address each gap. They layer on top of the existing tween system without replacing it.

---

## 1. Spring Physics

### 1.1 What a Spring Is

A spring is a stateful simulation with two evolving quantities: **position** and **velocity**. Each frame, the physics step computes acceleration from:

```
F = -k * (position - target) - c * velocity
a = F / mass
```

Where `k` is stiffness, `c` is damping, and `mass` is inertia. The position and velocity are integrated forward by delta-time.

The critical behavior: **when you change `target`, the spring inherits its current position and velocity and smoothly redirects**. No restart. No snap. The physics handles it.

### 1.2 Why RK4

Euler integration (`v += a * dt; x += v * dt`) is unstable when the timestep is large relative to the spring frequency. A 16ms frame at stiffness=300 already shows visible energy gain. Dropped frames (32ms+) make it worse — the spring gains energy and oscillates forever.

RK4 (4th-order Runge-Kutta) evaluates the derivative at four points per step, producing a weighted average. It is stable at UI timesteps for all reasonable stiffness/damping values, adds negligible cost (four multiply-add sequences per step), and requires no iteration or subdivision. One RK4 step per frame is sufficient.

### 1.3 Types

New file: `src/animation/spring.zig`

```zig
const std = @import("std");
const platform = @import("../platform/mod.zig");

/// Hard limit on simultaneous springs (per CLAUDE.md: "put a limit on everything").
/// 256 springs * 48 bytes = 12KB. Typical UI: 5-20 springs.
pub const MAX_SPRINGS = 256;

/// Springs closer than this to target with velocity below this are considered at rest.
const DEFAULT_REST_THRESHOLD: f32 = 0.0005;

/// Maximum delta-time per step in seconds. Prevents instability on long frame drops.
/// If real dt exceeds this, we clamp rather than subdivide (simpler, predictable).
const MAX_DT: f32 = 0.064; // ~15fps floor

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
    pub const default = SpringConfig{};

    /// No bounce, fast settle. Good for opacity, color transitions.
    pub const snappy = SpringConfig{ .stiffness = 300, .damping = 30 };

    /// Visible bounce. Good for pop-in effects, attention-grabbing.
    pub const bouncy = SpringConfig{ .stiffness = 180, .damping = 12 };

    /// Slow, smooth. Good for background transitions, ambient motion.
    pub const gentle = SpringConfig{ .stiffness = 120, .damping = 20 };

    /// Very fast, no bounce. Good for micro-interactions, hover states.
    pub const stiff = SpringConfig{ .stiffness = 400, .damping = 40 };

    /// Wobbly — low damping, visible oscillation. Good for playful UI.
    pub const wobbly = SpringConfig{ .stiffness = 150, .damping = 8 };
};

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
    pub const zero = Self{ .value = 0.0, .velocity = 0.0, .at_rest = true, .state = null };

    /// A settled spring at position 1.
    pub const one = Self{ .value = 1.0, .velocity = 0.0, .at_rest = true, .state = null };

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
```

### 1.4 RK4 Integration

```zig
/// Compute spring acceleration from current state.
fn acceleration(pos: f32, vel: f32, target: f32, k: f32, c: f32, m: f32) f32 {
    // F = -k * displacement - c * velocity
    // a = F / m
    std.debug.assert(m > 0.0);
    return (-(k) * (pos - target) - c * vel) / m;
}

/// Advance spring state by dt seconds using RK4 integration.
/// Mutates state.position, state.velocity, state.at_rest.
pub fn stepSpring(state: *SpringState, dt_raw: f32) void {
    std.debug.assert(dt_raw >= 0.0);

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
```

### 1.5 Back-of-Envelope

- `SpringState` is 48 bytes (8 floats + 1 i64 + 1 bool + padding).
- Pool of `MAX_SPRINGS` (256) = **12KB**. Pre-allocatable. Well within WASM stack budget if pooled on heap.
- Per-frame cost per active spring: one RK4 step = ~20 multiply-adds. At 256 springs that's ~5,000 FLOPs — invisible next to GPU work.
- At-rest springs cost one branch (the early return in `tickSpring`). Zero physics work.

### 1.6 WidgetStore Integration

Changes to `src/context/widget_store.zig`:

```zig
// New field alongside existing `animations`:
springs: std.AutoArrayHashMap(u32, SpringState),
active_spring_count: u32 = 0,
```

Init in `WidgetStore.init`:

```zig
.springs = std.AutoArrayHashMap(u32, SpringState).init(allocator),
```

Deinit in `WidgetStore.deinit`:

```zig
self.springs.deinit();
```

New methods — follow exact pattern of `animateById` / `animateOnById`:

```zig
const spring_mod = @import("../animation/spring.zig");
const SpringState = spring_mod.SpringState;
const SpringConfig = spring_mod.SpringConfig;
const SpringHandle = spring_mod.SpringHandle;
const hashString = @import("../animation/animation.zig").hashString;

/// Get or create a spring by hashed ID. The target is declarative:
/// set it every frame, and the spring smoothly tracks it.
pub fn springById(self: *Self, spring_id: u32, config: SpringConfig) SpringHandle {
    // Enforce pool limit
    if (self.springs.count() >= spring_mod.MAX_SPRINGS) {
        if (self.springs.getPtr(spring_id) == null) {
            // New spring but pool is full — return settled at target
            return .{
                .value = config.target,
                .velocity = 0.0,
                .at_rest = true,
                .state = null,
            };
        }
    }

    const gop = self.springs.getOrPut(spring_id) catch {
        return SpringHandle.one;
    };

    if (!gop.found_existing) {
        gop.value_ptr.* = SpringState.init(config);
    } else {
        // Update target — this is the interruptibility mechanism.
        // Position and velocity are preserved; only the destination changes.
        // Wake the spring if target changed (critical: at_rest springs skip physics).
        const target_changed = gop.value_ptr.target != config.target;
        gop.value_ptr.target = config.target;
        // Allow runtime config changes (e.g., stiffer spring when urgent)
        gop.value_ptr.stiffness = config.stiffness;
        gop.value_ptr.damping = config.damping;
        gop.value_ptr.mass = config.mass;

        if (target_changed and gop.value_ptr.at_rest) {
            gop.value_ptr.at_rest = false;
            // Reset timestamp so first dt after wake is reasonable
            // (will be clamped to MAX_DT by stepSpring if stale)
            gop.value_ptr.last_time_ms = platform.time.milliTimestamp();
        }
    }

    const handle = spring_mod.tickSpring(gop.value_ptr);
    if (!handle.at_rest) {
        self.active_spring_count += 1;
    }
    return handle;
}

pub fn spring(self: *Self, id: []const u8, config: SpringConfig) SpringHandle {
    return self.springById(hashString(id), config);
}

// Update existing hasActiveAnimations to include springs:
pub fn hasActiveAnimations(self: *const Self) bool {
    return self.active_animation_count > 0
        or self.active_spring_count > 0;
}
```

Update `beginFrame`:

```zig
pub fn beginFrame(self: *Self) void {
    self.accessed_this_frame.clearRetainingCapacity();
    self.active_animation_count = 0;
    self.active_spring_count = 0;
}
```

### 1.7 Gooey Integration

No changes needed to `src/context/gooey.zig`. The existing `endFrame` already calls `self.widgets.hasActiveAnimations()` and requests a re-render. Since we updated `hasActiveAnimations` above to include `active_spring_count`, springs get frame scheduling for free.

### 1.8 Cx API

Changes to `src/cx.zig`:

````zig
const spring_mod = @import("animation/spring.zig");
const SpringConfig = spring_mod.SpringConfig;
const SpringHandle = spring_mod.SpringHandle;

// =========================================================================
// Spring API
// =========================================================================

/// Declarative spring animation. Set the target every frame;
/// the spring smoothly tracks it, inheriting velocity on interruption.
///
/// ```zig
/// const s = cx.spring("panel-height", .{
///     .target = if (expanded) 1.0 else 0.0,
///     .stiffness = 200,
///     .damping = 20,
/// });
/// const height = lerp(0.0, 300.0, s.clamped());
/// ```
pub fn springComptime(self: *Self, comptime id: []const u8, config: SpringConfig) SpringHandle {
    const spring_id = comptime animation_mod.hashString(id);
    return self._gooey.widgets.springById(spring_id, config);
}

/// Runtime string spring API (for dynamic IDs).
pub fn spring(self: *Self, id: []const u8, config: SpringConfig) SpringHandle {
    return self._gooey.widgets.spring(id, config);
}
````

### 1.9 root.zig Re-exports

```zig
pub const spring_mod = @import("animation/spring.zig");
pub const SpringConfig = spring_mod.SpringConfig;
pub const SpringHandle = spring_mod.SpringHandle;
```

### 1.10 mod.zig Re-exports

Add to `src/animation/mod.zig`:

```zig
pub const spring = @import("spring.zig");
pub const SpringConfig = spring.SpringConfig;
pub const SpringHandle = spring.SpringHandle;
pub const SpringState = spring.SpringState;
```

### 1.11 Usage Example: Before and After

**Before (tween, no velocity inheritance):**

```zig
const PanelSection = struct {
    show: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const slide = cx.animateOn("panel-slide", self.show, .{
            .duration_ms = 400,
            .easing = Easing.easeOutCubic,
        });

        if (self.show or slide.running) {
            const progress = if (self.show) slide.progress else 1.0 - slide.progress;
            cx.render(ui.box(.{
                .height = 100.0 * progress,
                .background = Color.blue.withAlpha(progress),
            }, .{ /* ... */ }));
        }
    }
};
```

Rapid toggle: panel snaps to 0, restarts 400ms tween. Jarring.

**After (spring, velocity inheritance):**

```zig
const PanelSection = struct {
    show: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.spring("panel-spring", .{
            .target = if (self.show) 1.0 else 0.0,
            .stiffness = 200,
            .damping = 22,
        });

        if (s.value > 0.001 or !s.at_rest) {
            cx.render(ui.box(.{
                .height = 100.0 * s.clamped(),
                .background = Color.blue.withAlpha(s.clamped()),
            }, .{ /* ... */ }));
        }
    }
};
```

Rapid toggle: panel smoothly reverses mid-flight, inheriting current velocity. Physically grounded.

### 1.12 Tests

```zig
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
    var state = SpringState.init(.{ .target = 1.0, .initial_position = 0.0, .stiffness = 200, .damping = 10 });
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
```

---

## 2. Motion Containers

### 2.1 Problem

Every show/hide component repeats the same pattern:

1. Use `animateOn` with the visibility boolean as trigger
2. Keep rendering during exit: `if (self.show or anim.running)`
3. Manually reverse progress: `if (self.show) anim.progress else 1.0 - anim.progress`
4. Hope `initSettled` does the right thing on first mount

This is error-prone. Forgetting step 2 makes the component vanish instantly. Forgetting step 3 makes the exit animation play forward instead of backward.

### 2.2 Design

A motion container is a **lifecycle wrapper** that manages enter/exit state and exposes a single `progress` value that goes 0→1 on enter and 1→0 on exit. It keeps the component "visible" during the exit animation.

There are two flavors:

- **Tween-based motion**: fixed duration enter/exit, easing curves. Familiar, predictable timing.
- **Spring-based motion**: spring physics for both enter and exit. Interruptible. Preferred for interactive UI.

Both are stored in `WidgetStore` alongside animations and springs.

### 2.3 Types

New file: `src/animation/motion.zig`

```zig
const std = @import("std");
const platform = @import("../platform/mod.zig");
const animation = @import("animation.zig");
const spring_mod = @import("spring.zig");

/// Hard limit on simultaneous motion containers.
pub const MAX_MOTIONS = 256;

pub const MotionPhase = enum {
    /// Enter animation is playing (progress going 0→1)
    entering,
    /// Fully entered and visible (progress = 1.0)
    entered,
    /// Exit animation is playing (progress going 1→0)
    exiting,
    /// Fully exited and invisible (progress = 0.0)
    exited,
};

/// Tween-based motion container configuration.
/// NOTE: Tween motions restart from progress=0 on interruption (rapid toggle).
/// For smooth interruptible enter/exit, use `SpringMotionConfig` instead.
pub const MotionConfig = struct {
    /// Tween config for the enter transition.
    enter: animation.AnimationConfig = .{ .duration_ms = 250, .easing = animation.Easing.easeOutCubic },

    /// Tween config for the exit transition.
    /// If null, uses enter config (symmetric).
    exit: ?animation.AnimationConfig = null,

    /// If true, start in the "entered" state (visible, progress=1) on first mount.
    /// If false (default), play the enter animation on first mount.
    start_visible: bool = false,

    // =========================================================================
    // Presets
    // =========================================================================

    /// Quick fade in/out
    pub const fade = MotionConfig{
        .enter = .{ .duration_ms = 200 },
        .exit = .{ .duration_ms = 150, .easing = animation.Easing.easeIn },
    };

    /// Slide + fade
    pub const slide = MotionConfig{
        .enter = .{ .duration_ms = 300, .easing = animation.Easing.easeOutCubic },
        .exit = .{ .duration_ms = 200, .easing = animation.Easing.easeIn },
    };

    /// Pop in with overshoot, quick fade out
    pub const pop = MotionConfig{
        .enter = .{ .duration_ms = 250, .easing = animation.Easing.easeOutBack },
        .exit = .{ .duration_ms = 150, .easing = animation.Easing.easeIn },
    };

    fn exitConfig(self: MotionConfig) animation.AnimationConfig {
        return self.exit orelse self.enter;
    }
};

pub const SpringMotionConfig = struct {
    /// Spring config for both enter and exit. Target is managed automatically.
    spring: spring_mod.SpringConfig = spring_mod.SpringConfig.default,

    /// If true, start in the "entered" state on first mount.
    start_visible: bool = false,

    pub const default = SpringMotionConfig{};
    pub const bouncy = SpringMotionConfig{ .spring = spring_mod.SpringConfig.bouncy };
    pub const snappy = SpringMotionConfig{ .spring = spring_mod.SpringConfig.snappy };
};

pub const MotionState = struct {
    phase: MotionPhase,
    /// The last `show` value we saw. Used to detect transitions.
    last_show: bool,
    /// Tween-based: separate enter/exit animation states.
    /// Only one is active at a time.
    enter_state: animation.AnimationState,
    exit_state: animation.AnimationState,
    /// Which config was used (needed for exit config lookup)
    enter_config: animation.AnimationConfig,
    exit_config: animation.AnimationConfig,
};

pub const SpringMotionState = struct {
    phase: MotionPhase,
    last_show: bool,
    spring_state: spring_mod.SpringState,
};

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
```

### 2.4 Tick Logic — Tween-Based Motion

```zig
/// Tick a tween-based motion container. Called by WidgetStore each frame.
pub fn tickMotion(state: *MotionState, show: bool) MotionHandle {
    std.debug.assert(state.enter_config.duration_ms > 0);
    std.debug.assert(state.exit_config.duration_ms > 0);

    // Detect show/hide transitions
    if (show != state.last_show) {
        state.last_show = show;
        if (show) {
            // Transition to entering
            state.phase = .entering;
            state.enter_state = animation.AnimationState.init(state.enter_config);
        } else {
            // Transition to exiting
            state.phase = .exiting;
            state.exit_state = animation.AnimationState.init(state.exit_config);
        }
    }

    switch (state.phase) {
        .entering => {
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
        },
        .entered => {
            return MotionHandle.shown;
        },
        .exiting => {
            const handle = animation.calculateProgress(&state.exit_state);
            if (!handle.running) {
                state.phase = .exited;
                return MotionHandle.hidden;
            }
            // Reverse progress: exit goes 1→0
            return .{
                .progress = 1.0 - handle.progress,
                .visible = true,
                .phase = .exiting,
            };
        },
        .exited => {
            return MotionHandle.hidden;
        },
    }
}
```

### 2.5 Tick Logic — Spring-Based Motion

```zig
/// Tick a spring-based motion container.
pub fn tickSpringMotion(state: *SpringMotionState, show: bool) MotionHandle {
    // Update target based on show state. The spring handles the rest.
    const target: f32 = if (show) 1.0 else 0.0;
    state.spring_state.target = target;
    state.last_show = show;

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

    // Spring is in flight
    if (show) {
        state.phase = .entering;
    } else {
        state.phase = .exiting;
    }

    return .{
        .progress = std.math.clamp(handle.value, 0.0, 1.0),
        .visible = true,
        .phase = state.phase,
    };
}
```

### 2.6 WidgetStore Integration

New fields:

```zig
motions: std.AutoArrayHashMap(u32, MotionState),
spring_motions: std.AutoArrayHashMap(u32, SpringMotionState),
active_motion_count: u32 = 0,
```

New methods:

```zig
/// Tween-based motion container.
pub fn motionById(self: *Self, motion_id: u32, show: bool, config: MotionConfig) MotionHandle {
    // Enforce pool limit
    if (self.motions.count() >= motion_mod.MAX_MOTIONS) {
        if (self.motions.getPtr(motion_id) == null) {
            return if (show) MotionHandle.shown else MotionHandle.hidden;
        }
    }

    const gop = self.motions.getOrPut(motion_id) catch {
        return if (show) MotionHandle.shown else MotionHandle.hidden;
    };

    if (!gop.found_existing) {
        const initial_phase: MotionPhase = if (config.start_visible) .entered else if (show) .entering else .exited;
        const enter_config = config.enter;
        const exit_config = config.exitConfig();
        gop.value_ptr.* = .{
            .phase = initial_phase,
            .last_show = if (config.start_visible) true else show,
            .enter_state = if (initial_phase == .entering)
                animation.AnimationState.init(enter_config)
            else
                animation.AnimationState.initSettled(enter_config, 0),
            .exit_state = animation.AnimationState.initSettled(exit_config, 0),
            .enter_config = enter_config,
            .exit_config = exit_config,
        };
        // If entering on first mount, we need to tick it
        if (initial_phase == .entering) {
            const handle = motion_mod.tickMotion(gop.value_ptr, show);
            if (handle.phase == .entering or handle.phase == .exiting) {
                self.active_motion_count += 1;
            }
            return handle;
        }
        return if (config.start_visible) MotionHandle.shown else MotionHandle.hidden;
    }

    const handle = motion_mod.tickMotion(gop.value_ptr, show);
    if (handle.phase == .entering or handle.phase == .exiting) {
        self.active_motion_count += 1;
    }
    return handle;
}

pub fn motion(self: *Self, id: []const u8, show: bool, config: MotionConfig) MotionHandle {
    return self.motionById(hashString(id), show, config);
}

/// Spring-based motion container.
pub fn springMotionById(self: *Self, motion_id: u32, show: bool, config: SpringMotionConfig) MotionHandle {
    // Enforce pool limit
    if (self.spring_motions.count() >= motion_mod.MAX_MOTIONS) {
        if (self.spring_motions.getPtr(motion_id) == null) {
            return if (show) MotionHandle.shown else MotionHandle.hidden;
        }
    }

    const gop = self.spring_motions.getOrPut(motion_id) catch {
        return if (show) MotionHandle.shown else MotionHandle.hidden;
    };

    if (!gop.found_existing) {
        const initial_target: f32 = if (config.start_visible) 1.0 else if (show) 1.0 else 0.0;
        var spring_config = config.spring;
        spring_config.target = initial_target;
        spring_config.initial_position = if (config.start_visible) 1.0 else 0.0;

        gop.value_ptr.* = .{
            .phase = if (config.start_visible) .entered else .exited,
            .last_show = if (config.start_visible) true else show,
            .spring_state = if (config.start_visible)
                spring_mod.SpringState.initSettled(spring_config)
            else
                spring_mod.SpringState.init(spring_config),
        };
    }

    const handle = motion_mod.tickSpringMotion(gop.value_ptr, show);
    if (handle.phase == .entering or handle.phase == .exiting) {
        self.active_motion_count += 1;
    }
    return handle;
}

pub fn springMotion(self: *Self, id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
    return self.springMotionById(hashString(id), show, config);
}
```

Update `hasActiveAnimations`:

```zig
pub fn hasActiveAnimations(self: *const Self) bool {
    return self.active_animation_count > 0
        or self.active_spring_count > 0
        or self.active_motion_count > 0;
}
```

Update `beginFrame`:

```zig
self.active_motion_count = 0;
```

### 2.7 Cx API

````zig
const motion_mod = @import("animation/motion.zig");
const MotionConfig = motion_mod.MotionConfig;
const MotionHandle = motion_mod.MotionHandle;
const SpringMotionConfig = motion_mod.SpringMotionConfig;

/// Tween-based motion container. Manages enter/exit lifecycle.
///
/// ```zig
/// const m = cx.motion("panel", show_panel, .fade);
/// if (m.visible) {
///     cx.render(ui.box(.{
///         .background = Color.blue.withAlpha(m.progress),
///     }, .{ /* ... */ }));
/// }
/// ```
pub fn motionComptime(self: *Self, comptime id: []const u8, show: bool, config: MotionConfig) MotionHandle {
    const mid = comptime animation_mod.hashString(id);
    return self._gooey.widgets.motionById(mid, show, config);
}

pub fn motion(self: *Self, id: []const u8, show: bool, config: MotionConfig) MotionHandle {
    return self._gooey.widgets.motion(id, show, config);
}

/// Spring-based motion container. Interruptible enter/exit.
///
/// ```zig
/// const m = cx.springMotion("modal", show_modal, .bouncy);
/// if (m.visible) {
///     cx.render(ui.box(.{
///         .width = lerp(0.0, 400.0, m.progress),
///     }, .{ /* ... */ }));
/// }
/// ```
pub fn springMotionComptime(self: *Self, comptime id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
    const mid = comptime animation_mod.hashString(id);
    return self._gooey.widgets.springMotionById(mid, show, config);
}

pub fn springMotion(self: *Self, id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
    return self._gooey.widgets.springMotion(id, show, config);
}
````

### 2.8 Usage Example: Before and After

**Before (manual lifecycle):**

```zig
pub fn render(self: @This(), cx: *Cx) void {
    const slide = cx.animateOn("panel-slide", self.show, .{
        .duration_ms = 400,
        .easing = Easing.easeOutCubic,
    });

    // Manual: keep rendering during exit
    if (self.show or slide.running) {
        // Manual: reverse progress on exit
        const progress = if (self.show) slide.progress else 1.0 - slide.progress;

        cx.render(ui.box(.{
            .background = Color.blue.withAlpha(progress),
            .height = 100.0 * progress,
        }, .{ /* ... */ }));
    }
}
```

**After (tween motion container):**

```zig
pub fn render(self: @This(), cx: *Cx) void {
    const m = cx.motion("panel", self.show, .slide);

    if (m.visible) {
        cx.render(ui.box(.{
            .background = Color.blue.withAlpha(m.progress),
            .height = 100.0 * m.progress,
        }, .{ /* ... */ }));
    }
}
```

**After (spring motion container — interruptible):**

```zig
pub fn render(self: @This(), cx: *Cx) void {
    const m = cx.springMotion("panel", self.show, .snappy);

    if (m.visible) {
        cx.render(ui.box(.{
            .background = Color.blue.withAlpha(m.progress),
            .height = 100.0 * m.progress,
        }, .{ /* ... */ }));
    }
}
```

### 2.9 Tests

```zig
test "tween motion: enter plays 0→1" {
    var state = MotionState{ ... }; // init as exited
    // First frame with show=true triggers entering
    const h1 = tickMotion(&state, true);
    try std.testing.expect(h1.visible);
    try std.testing.expect(h1.phase == .entering);
    try std.testing.expect(h1.progress >= 0.0);
    try std.testing.expect(h1.progress < 1.0);
}

test "tween motion: exit plays 1→0" {
    var state = MotionState{ ... }; // init as entered
    const h1 = tickMotion(&state, false);
    try std.testing.expect(h1.visible); // Still visible during exit!
    try std.testing.expect(h1.phase == .exiting);
    try std.testing.expect(h1.progress <= 1.0);
    try std.testing.expect(h1.progress > 0.0);
}

test "tween motion: not visible after exit completes" {
    // Advance past exit duration...
    const h = tickMotion(&state, false);
    try std.testing.expect(!h.visible);
    try std.testing.expect(h.phase == .exited);
}

test "spring motion: rapid toggle doesn't snap" {
    var state = SpringMotionState{ ... }; // init with show=true
    // Enter partway
    _ = tickSpringMotion(&state, true);
    // Immediately toggle off
    const h = tickSpringMotion(&state, false);
    // Should be visible (exit in progress) and progress > 0
    try std.testing.expect(h.visible);
    try std.testing.expect(h.progress > 0.0);
}
```

---

## 3. Stagger Animations

### 3.1 Problem

Rendering a list where items cascade in one-by-one requires manual delay math:

```zig
for (items, 0..) |_, i| {
    const delay = @as(u32, @intCast(i)) * 50;
    const anim = cx.animate(item_id, .{ .duration_ms = 200, .delay_ms = delay });
    // ...
}
```

This has issues: you need a unique ID per item (dynamic string formatting or hash combining), the delay calculation is ad-hoc, and there's no support for reverse or center-out stagger patterns.

### 3.2 Design

Stagger is a **thin computation layer** on top of the existing animation system. It:

1. Combines a base animation ID with an item index to produce a unique per-item ID (hash combination, no string formatting).
2. Computes the per-item delay from the index, total count, and stagger direction.
3. Calls the existing `animateById` with the computed delay.
4. Caps total stagger time to prevent unbounded delays.

No new state type is needed. Each staggered item is a normal `AnimationState` in the existing pool.

### 3.3 Types

New file: `src/animation/stagger.zig`

```zig
const std = @import("std");
const animation = @import("animation.zig");

/// Maximum items in a single stagger group (per CLAUDE.md: limit everything).
pub const MAX_STAGGER_ITEMS: u32 = 512;

/// Maximum total stagger delay in milliseconds. Prevents a 1000-item list
/// from having a 50-second cascade.
pub const MAX_STAGGER_DELAY_MS: u32 = 2000;

pub const StaggerDirection = enum {
    /// First item animates first, last item last.
    forward,
    /// Last item animates first, first item last.
    reverse,
    /// Center items animate first, edges last.
    from_center,
    /// Edge items animate first, center last.
    from_edges,
};

pub const StaggerConfig = struct {
    /// Base animation config applied to each item.
    animation: animation.AnimationConfig = .{ .duration_ms = 200, .easing = animation.Easing.easeOutCubic },

    /// Delay between consecutive items in milliseconds.
    per_item_ms: u32 = 50,

    /// Stagger direction.
    direction: StaggerDirection = .forward,

    /// Maximum total delay across all items. 0 = use MAX_STAGGER_DELAY_MS.
    max_total_delay_ms: u32 = 0,

    // =========================================================================
    // Presets
    // =========================================================================

    /// Quick cascade, good for menu items.
    pub const fast = StaggerConfig{ .per_item_ms = 30, .animation = .{ .duration_ms = 150 } };

    /// Standard list entry.
    pub const list = StaggerConfig{ .per_item_ms = 50, .animation = .{ .duration_ms = 200, .easing = animation.Easing.easeOutCubic } };

    /// Slow reveal, good for hero sections.
    pub const reveal = StaggerConfig{ .per_item_ms = 80, .animation = .{ .duration_ms = 300, .easing = animation.Easing.easeOutQuint } };

    /// Pop in from center, good for grids.
    pub const grid_pop = StaggerConfig{
        .per_item_ms = 40,
        .direction = .from_center,
        .animation = .{ .duration_ms = 250, .easing = animation.Easing.easeOutBack },
    };
};

/// Combine a base animation ID hash with an item index to produce
/// a unique per-item ID. Uses xor + mixing to avoid collisions.
pub fn staggerItemId(base_id: u32, index: u32) u32 {
    // Murmur-style mix: xor then multiply-shift
    var h = base_id ^ (index *% 0x9e3779b9);
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    // AnimationId 0 is reserved — remap on collision (theoretically possible but rare)
    return if (h == 0) 1 else h;
}

/// Compute the delay for a specific item in a stagger group.
pub fn computeStaggerDelay(
    index: u32,
    total_count: u32,
    config: StaggerConfig,
) u32 {
    std.debug.assert(total_count > 0);
    std.debug.assert(index < total_count);

    if (total_count == 1) return 0;

    const max_delay = if (config.max_total_delay_ms > 0)
        config.max_total_delay_ms
    else
        MAX_STAGGER_DELAY_MS;

    const position: u32 = switch (config.direction) {
        .forward => index,
        .reverse => total_count - 1 - index,
        .from_center => blk: {
            const center = (total_count - 1) / 2;
            const dist = if (index >= center) index - center else center - index;
            break :blk dist;
        },
        .from_edges => blk: {
            // Distance from nearest edge: 0 at edges, max in center.
            // Symmetric for both even and odd counts.
            break :blk @min(index, total_count - 1 - index);
        },
    };

    const raw_delay = position * config.per_item_ms;
    return @min(raw_delay, max_delay);
}
```

### 3.4 WidgetStore Integration

No new state storage needed. Staggered items are regular `AnimationState` entries.

New method:

```zig
const stagger_mod = @import("../animation/stagger.zig");
const StaggerConfig = stagger_mod.StaggerConfig;

/// Animate a single item within a stagger group.
/// Call once per item per frame inside a list render loop.
pub fn staggerById(
    self: *Self,
    base_id: u32,
    index: u32,
    total_count: u32,
    config: StaggerConfig,
) AnimationHandle {
    std.debug.assert(index < total_count);
    std.debug.assert(total_count <= stagger_mod.MAX_STAGGER_ITEMS);

    const item_id = stagger_mod.staggerItemId(base_id, index);
    const delay = stagger_mod.computeStaggerDelay(index, total_count, config);

    var item_config = config.animation;
    item_config.delay_ms = config.animation.delay_ms + delay;

    return self.animateById(item_id, item_config);
}

pub fn stagger(
    self: *Self,
    id: []const u8,
    index: u32,
    total_count: u32,
    config: StaggerConfig,
) AnimationHandle {
    return self.staggerById(hashString(id), index, total_count, config);
}
```

### 3.5 Cx API

````zig
const stagger_mod = @import("animation/stagger.zig");
const StaggerConfig = stagger_mod.StaggerConfig;

/// Staggered animation for list items. Each item gets its own animation
/// with a computed delay based on its index and the stagger direction.
///
/// ```zig
/// for (items, 0..) |item, i| {
///     const anim = cx.stagger("list-enter", @intCast(i), @intCast(items.len), .list);
///     cx.render(ui.box(.{
///         .background = Color.white.withAlpha(anim.progress),
///     }, .{ ui.text(item.name, .{}) }));
/// }
/// ```
pub fn staggerComptime(
    self: *Self,
    comptime id: []const u8,
    index: u32,
    total_count: u32,
    config: StaggerConfig,
) AnimationHandle {
    const base_id = comptime animation_mod.hashString(id);
    return self._gooey.widgets.staggerById(base_id, index, total_count, config);
}

pub fn stagger(
    self: *Self,
    id: []const u8,
    index: u32,
    total_count: u32,
    config: StaggerConfig,
) AnimationHandle {
    return self._gooey.widgets.stagger(id, index, total_count, config);
}
````

### 3.6 Usage Example

**Before (manual delays, manual IDs):**

```zig
for (items, 0..) |item, i| {
    var buf: [64]u8 = undefined;
    const item_id = std.fmt.bufPrint(&buf, "item-{}", .{i}) catch "item-?";
    const delay = @as(u32, @intCast(i)) * 50;
    const anim = cx.animate(item_id, .{
        .duration_ms = 200,
        .delay_ms = delay,
        .easing = Easing.easeOutCubic,
    });
    cx.render(ui.box(.{
        .background = Color.white.withAlpha(anim.progress),
    }, .{ ui.text(item.name, .{}) }));
}
```

**After:**

```zig
for (items, 0..) |item, i| {
    const anim = cx.stagger("list-enter", @intCast(i), @intCast(items.len), .list);
    cx.render(ui.box(.{
        .background = Color.white.withAlpha(anim.progress),
    }, .{ ui.text(item.name, .{}) }));
}
```

**Center-out grid reveal:**

```zig
for (grid_items, 0..) |item, i| {
    const anim = cx.stagger("grid-reveal", @intCast(i), @intCast(grid_items.len), .grid_pop);
    const scale = 0.8 + 0.2 * anim.progress;
    cx.render(ui.box(.{
        .width = 80 * scale,
        .height = 80 * scale,
        .background = item.color.withAlpha(anim.progress),
        .corner_radius = 8,
    }, .{}));
}
```

### 3.7 Tests

```zig
test "stagger delay: forward direction" {
    const delay_0 = computeStaggerDelay(0, 5, .{ .per_item_ms = 50 });
    const delay_1 = computeStaggerDelay(1, 5, .{ .per_item_ms = 50 });
    const delay_4 = computeStaggerDelay(4, 5, .{ .per_item_ms = 50 });
    try std.testing.expectEqual(@as(u32, 0), delay_0);
    try std.testing.expectEqual(@as(u32, 50), delay_1);
    try std.testing.expectEqual(@as(u32, 200), delay_4);
}

test "stagger delay: reverse direction" {
    const delay_0 = computeStaggerDelay(0, 5, .{ .per_item_ms = 50, .direction = .reverse });
    const delay_4 = computeStaggerDelay(4, 5, .{ .per_item_ms = 50, .direction = .reverse });
    try std.testing.expectEqual(@as(u32, 200), delay_0); // First item has max delay
    try std.testing.expectEqual(@as(u32, 0), delay_4);   // Last item has zero delay
}

test "stagger delay: from_center" {
    // 5 items, center is index 2
    const delay_2 = computeStaggerDelay(2, 5, .{ .per_item_ms = 50, .direction = .from_center });
    const delay_0 = computeStaggerDelay(0, 5, .{ .per_item_ms = 50, .direction = .from_center });
    const delay_4 = computeStaggerDelay(4, 5, .{ .per_item_ms = 50, .direction = .from_center });
    try std.testing.expectEqual(@as(u32, 0), delay_2);   // Center = no delay
    try std.testing.expectEqual(@as(u32, 100), delay_0);  // 2 away from center
    try std.testing.expectEqual(@as(u32, 100), delay_4);  // 2 away from center
}

test "stagger delay respects max_total_delay_ms" {
    const delay = computeStaggerDelay(999, 1000, .{ .per_item_ms = 50, .max_total_delay_ms = 500 });
    try std.testing.expect(delay <= 500);
}

test "stagger item IDs are unique" {
    const base: u32 = 12345;
    const id_0 = staggerItemId(base, 0);
    const id_1 = staggerItemId(base, 1);
    const id_2 = staggerItemId(base, 2);
    try std.testing.expect(id_0 != id_1);
    try std.testing.expect(id_1 != id_2);
    try std.testing.expect(id_0 != id_2);
}

test "single item stagger has zero delay" {
    const delay = computeStaggerDelay(0, 1, .{ .per_item_ms = 50 });
    try std.testing.expectEqual(@as(u32, 0), delay);
}
```

---

## File Plan

| File                           | Action     | Description                                                                                                                      |
| ------------------------------ | ---------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `src/animation/spring.zig`     | **Create** | `SpringConfig`, `SpringState`, `SpringHandle`, RK4 integration, `tickSpring`, tests                                              |
| `src/animation/motion.zig`     | **Create** | `MotionConfig`, `SpringMotionConfig`, `MotionState`, `SpringMotionState`, `MotionHandle`, `MotionPhase`, tick functions, tests   |
| `src/animation/stagger.zig`    | **Create** | `StaggerConfig`, `StaggerDirection`, `staggerItemId`, `computeStaggerDelay`, tests                                               |
| `src/animation/mod.zig`        | **Edit**   | Re-export spring, motion, stagger types                                                                                          |
| `src/context/widget_store.zig` | **Edit**   | Add spring/motion/stagger storage and methods                                                                                    |
| `src/context/gooey.zig`        | **None**   | No changes needed — `hasActiveAnimations` is consolidated in `widget_store.zig`                                                  |
| `src/cx.zig`                   | **Edit**   | Add `spring`, `springComptime`, `motion`, `motionComptime`, `springMotion`, `springMotionComptime`, `stagger`, `staggerComptime` |
| `src/root.zig`                 | **Edit**   | Re-export `SpringConfig`, `SpringHandle`, `MotionConfig`, `MotionHandle`, `SpringMotionConfig`, `StaggerConfig`                  |
| `src/examples/animation.zig`   | **Edit**   | Update PanelSection to use `cx.motion` or `cx.springMotion`, add stagger list demo                                               |

---

## Struct Size Budget

Per CLAUDE.md WASM stack awareness — verify these are small:

| Struct              | Estimated Size | Notes                                                   |
| ------------------- | -------------- | ------------------------------------------------------- |
| `SpringState`       | 48 bytes       | 7 floats (28) + 1 i64 (8) + 1 bool (1) + padding        |
| `SpringConfig`      | 24 bytes       | 6 floats                                                |
| `SpringHandle`      | 24 bytes       | 2 floats + 1 bool + 1 pointer                           |
| `MotionState`       | ~200 bytes     | 2 `AnimationState` + 2 `AnimationConfig` + phase + bool |
| `SpringMotionState` | ~56 bytes      | `SpringState` (48) + phase + bool                       |
| `MotionHandle`      | 12 bytes       | 1 float + 1 bool + 1 enum                               |
| `StaggerConfig`     | 20 bytes       | `AnimationConfig` (16) + u32 + enum + u32               |

Pool totals at max capacity:

- 256 springs × 48B = **12KB**
- 256 motions × 200B = **50KB**
- 256 spring motions × 56B = **14KB**
- Stagger: zero additional storage (uses existing animation pool)

All well within budget. All heap-allocated in `WidgetStore` via `AutoArrayHashMap`.

---

## Limits Summary

```
MAX_SPRINGS = 256
MAX_MOTIONS = 256          (tween-based motion containers)
MAX_SPRING_MOTIONS = 256   (spring-based motion containers)
MAX_STAGGER_ITEMS = 512    (items per stagger group)
MAX_STAGGER_DELAY_MS = 2000 (cap total cascade time)
MAX_DT = 0.064             (spring timestep clamp, ~15fps floor)
```

---

## Implementation Order

1. ~~**`spring.zig`** — Self-contained, no dependencies on other new code. Write the RK4 integrator, `SpringState`, `SpringHandle`, tests. Verify stability with the RK4 tests before touching anything else.~~ ✅

2. ~~**Wire springs into `widget_store.zig` → `gooey.zig` → `cx.zig` → `root.zig`** — Get `cx.spring()` working end-to-end. Test with the existing spaceship demo (replace a `cx.animateComptime` pulse with a spring).~~ ✅

3. ~~**`stagger.zig`** — Pure computation, no state. Write `computeStaggerDelay`, `staggerItemId`, tests. Wire into `widget_store.zig` → `cx.zig` → `root.zig`.~~ ✅

4. ~~**`motion.zig`** — Depends on both `animation.zig` and `spring.zig`. Write `tickMotion`, `tickSpringMotion`, tests. Wire into `widget_store.zig` → `cx.zig` → `root.zig`.~~ ✅

5. ~~**Update `animation.zig` example** — Rewrite `PanelSection` to use `cx.springMotion`. Add a staggered list section to the demo.~~ ✅

6. ~~**`mod.zig` and `root.zig` re-exports** — Final wiring.~~ ✅

Steps 1 and 3 are independent (can be done in parallel). Step 4 depends on step 1. Step 5 depends on steps 2, 3, and 4.
