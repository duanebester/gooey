//! AnimationStore — retained per-window storage for animation pools.
//!
//! Hosts the four u32-keyed `AutoArrayHashMapUnmanaged` pools that
//! drive every tween, spring, stagger, and motion in the framework:
//!
//!   - `animations` — `AnimationState` (tween)
//!   - `springs` — `SpringState`
//!   - `motions` — `MotionState` (tween-based motion containers)
//!   - `spring_motions` — `SpringMotionState`
//!
//! ## Why this exists (and why it lives here, not in `context/`)
//!
//! Pre-PR-8.4c the four pools lived on `context/widget_store.zig`'s
//! `WidgetStore`, sharing space with the per-widget retained-state maps
//! (`select_states`, `scroll_containers`, `text_inputs`, `text_areas`,
//! `code_editors`). PR 8.1-8.4b peeled every per-widget map off
//! `WidgetStore` onto `Window.element_states` (the unified
//! `(type_id, id_hash) -> *S` keyed pool). What was left fit the
//! "cross-cutting per-window animation storage" shape — one widget
//! can drive multiple concurrent animations against different ids,
//! so they can't go on the per-element pool — and is owned naturally
//! by `animation/`, not `context/`. PR 8.4c lifts them here and
//! retires the `WidgetStore` namespace entirely. See
//! `docs/cleanup-implementation-plan.md` PR 8.4c.
//!
//! ## What's NOT here
//!
//! `ChangeTracker` (the `cx.changed(key, value)` backing storage)
//! lived alongside the animation pools on `WidgetStore` pre-PR-8.4c
//! but is unrelated to animation lifecycle — it's per-frame value-
//! diffing across arbitrary keys. PR 8.4c promotes it to a direct
//! `Window.change_tracker: ChangeTracker` field. The two subsystems
//! were only colocated because `WidgetStore` was the historical
//! "miscellaneous retained-storage" bucket.
//!
//! ## Frame-driven eviction (deferred)
//!
//! Each pool retains entries indefinitely until the caller invokes
//! `removeAnimation` / `swapRemove` explicitly. The `animateById` /
//! `animateOnById` paths use `last_queried_frame + frame_counter`
//! heuristics to detect "completed AND not queried last frame"
//! (component was hidden) and restart on re-mount, but that is not
//! the same shape as GPUI's two-frame swap-discipline eviction
//! against `next_frame` / `rendered_frame`. Lifting these pools onto
//! `Frame` with carry-forward fall-through is tracked alongside the
//! rest of the per-frame transients (`focus`, `mouse_listeners`,
//! `tab_stops`) that PR 7c.3 deferred for the same reason. See
//! `context/frame.zig` for the existing double buffer that anchors
//! the future migration.

const std = @import("std");
const animation = @import("animation.zig");
const AnimationState = animation.AnimationState;
const AnimationConfig = animation.AnimationConfig;
const AnimationHandle = animation.AnimationHandle;
const AnimationId = animation.AnimationId;
const spring_mod = @import("spring.zig");
const SpringState = spring_mod.SpringState;
const SpringConfig = spring_mod.SpringConfig;
const SpringHandle = spring_mod.SpringHandle;
const stagger_mod = @import("stagger.zig");
const StaggerConfig = stagger_mod.StaggerConfig;
const motion_mod = @import("motion.zig");
const MotionConfig = motion_mod.MotionConfig;
const MotionHandle = motion_mod.MotionHandle;
const MotionPhase = motion_mod.MotionPhase;
const MotionState = motion_mod.MotionState;
const SpringMotionConfig = motion_mod.SpringMotionConfig;
const SpringMotionState = motion_mod.SpringMotionState;
const hashString = animation.hashString;

pub const AnimationStore = struct {
    allocator: std.mem.Allocator,
    /// IO instance for monotonic timing. Stored on the struct because
    /// animations sample the `awake` clock every frame and callers
    /// (e.g. `cx.animations.tween`) come through methods, not free
    /// functions. `std.Io` is a pair of pointers into a
    /// process-lifetime vtable — safe and cheap to copy.
    io: std.Io,

    // u32-keyed animation storage
    animations: std.AutoArrayHashMapUnmanaged(u32, AnimationState),
    active_animation_count: u32 = 0,
    frame_counter: u64 = 1,

    // u32-keyed spring storage
    springs: std.AutoArrayHashMapUnmanaged(u32, SpringState),
    active_spring_count: u32 = 0,

    // u32-keyed motion storage (tween-based and spring-based)
    motions: std.AutoArrayHashMapUnmanaged(u32, MotionState),
    spring_motions: std.AutoArrayHashMapUnmanaged(u32, SpringMotionState),
    active_motion_count: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .animations = .empty,
            .springs = .empty,
            .motions = .empty,
            .spring_motions = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.animations.deinit(self.allocator);
        self.springs.deinit(self.allocator);
        self.motions.deinit(self.allocator);
        self.spring_motions.deinit(self.allocator);
    }

    // =========================================================================
    // Animation Methods (OPTIMIZED with u32 keys)
    // =========================================================================

    /// Get or create animation by hashed ID (no string allocation)
    pub fn animateById(self: *Self, anim_id: u32, config: AnimationConfig) AnimationHandle {
        const gop = self.animations.getOrPut(self.allocator, anim_id) catch {
            return AnimationHandle.complete;
        };

        if (!gop.found_existing) {
            gop.value_ptr.* = AnimationState.init(self.io, config);
            gop.value_ptr.last_queried_frame = self.frame_counter;
        } else if (!gop.value_ptr.running and self.frame_counter > gop.value_ptr.last_queried_frame + 1) {
            // Animation completed AND wasn't queried last frame (component was hidden).
            // Restart so mount/stagger animations replay on re-appearance.
            const gen = gop.value_ptr.generation +% 1;
            gop.value_ptr.* = AnimationState.init(self.io, config);
            gop.value_ptr.generation = gen;
            gop.value_ptr.last_queried_frame = self.frame_counter;
        } else {
            gop.value_ptr.last_queried_frame = self.frame_counter;
        }

        const handle = animation.calculateProgress(gop.value_ptr, self.io);
        if (handle.running) {
            self.active_animation_count += 1;
        }
        return handle;
    }

    /// String-based API (hashes at call site)
    pub fn animate(self: *Self, id: []const u8, config: AnimationConfig) AnimationHandle {
        return self.animateById(animation.hashString(id), config);
    }

    /// Restart animation by hashed ID
    pub fn restartAnimationById(self: *Self, anim_id: u32, config: AnimationConfig) AnimationHandle {
        const gop = self.animations.getOrPut(self.allocator, anim_id) catch {
            return AnimationHandle.complete;
        };

        // Always reset the animation state (whether existing or new)
        gop.value_ptr.* = AnimationState.init(self.io, config);
        gop.value_ptr.last_queried_frame = self.frame_counter;

        // If it was existing, preserve generation continuity
        if (gop.found_existing) {
            gop.value_ptr.generation +%= 1;
        }

        self.active_animation_count += 1;
        return animation.calculateProgress(gop.value_ptr, self.io);
    }

    /// String-based restart API
    pub fn restartAnimation(self: *Self, id: []const u8, config: AnimationConfig) AnimationHandle {
        return self.restartAnimationById(animation.hashString(id), config);
    }

    /// OPTIMIZED animateOn - single HashMap lookup!
    /// Trigger hash is now stored IN the AnimationState
    pub fn animateOnById(self: *Self, anim_id: u32, trigger_hash: u64, config: AnimationConfig) AnimationHandle {
        const gop = self.animations.getOrPut(self.allocator, anim_id) catch {
            return AnimationHandle.complete;
        };

        if (gop.found_existing) {
            // Check if trigger changed
            if (gop.value_ptr.trigger_hash != trigger_hash) {
                // Trigger changed - restart animation and update hash.
                // Monotonic clock so the resulting `elapsed` stays non-negative
                // even if the wall clock later jumps.
                gop.value_ptr.start_time = std.Io.Timestamp.now(self.io, .awake);
                gop.value_ptr.duration_ms = config.duration_ms;
                gop.value_ptr.delay_ms = config.delay_ms;
                gop.value_ptr.easing = config.easing;
                gop.value_ptr.mode = config.mode;
                gop.value_ptr.running = true;
                gop.value_ptr.forward = true;
                gop.value_ptr.generation +%= 1;
                gop.value_ptr.trigger_hash = trigger_hash;
            }
            gop.value_ptr.last_queried_frame = self.frame_counter;
        } else {
            // New animation - start in settled/idle state (not running).
            // This prevents components like modals from briefly appearing
            // on the first frame before any state change has occurred.
            gop.value_ptr.* = AnimationState.initSettled(config, trigger_hash);
            gop.value_ptr.last_queried_frame = self.frame_counter;
        }

        const handle = animation.calculateProgress(gop.value_ptr, self.io);
        if (handle.running) {
            self.active_animation_count += 1;
        }
        return handle;
    }

    /// String-based animateOn API
    pub fn animateOn(self: *Self, id: []const u8, trigger_hash: u64, config: AnimationConfig) AnimationHandle {
        return self.animateOnById(animation.hashString(id), trigger_hash, config);
    }

    pub fn isAnimatingById(self: *Self, anim_id: u32) bool {
        if (self.animations.getPtr(anim_id)) |state| {
            return state.running;
        }
        return false;
    }

    pub fn isAnimating(self: *Self, id: []const u8) bool {
        return self.isAnimatingById(animation.hashString(id));
    }

    pub fn getAnimationById(self: *Self, anim_id: u32) ?AnimationHandle {
        if (self.animations.getPtr(anim_id)) |state| {
            const handle = animation.calculateProgress(state, self.io);
            if (handle.running) {
                self.active_animation_count += 1;
            }
            return handle;
        }
        return null;
    }

    pub fn getAnimation(self: *Self, id: []const u8) ?AnimationHandle {
        return self.getAnimationById(animation.hashString(id));
    }

    pub fn removeAnimationById(self: *Self, anim_id: u32) void {
        _ = self.animations.swapRemove(anim_id);
    }

    pub fn removeAnimation(self: *Self, id: []const u8) void {
        self.removeAnimationById(animation.hashString(id));
    }

    /// Check if any animations or springs are active this frame
    pub fn hasActiveAnimations(self: *const Self) bool {
        return self.active_animation_count > 0 or self.active_spring_count > 0 or self.active_motion_count > 0;
    }

    // =========================================================================
    // Spring Methods
    // =========================================================================

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

        const gop = self.springs.getOrPut(self.allocator, spring_id) catch {
            return SpringHandle.one;
        };

        if (!gop.found_existing) {
            gop.value_ptr.* = SpringState.init(self.io, config);
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
                // Reset timestamp so first dt after wake is reasonable.
                // `awake` is monotonic, so `tickSpring`'s `durationTo` is
                // guaranteed non-negative even on long frame drops
                // (the result will be clamped to MAX_DT in stepSpring).
                gop.value_ptr.last_time = std.Io.Timestamp.now(self.io, .awake);
            }
        }

        const handle = spring_mod.tickSpring(self.io, gop.value_ptr);
        if (!handle.at_rest) {
            self.active_spring_count += 1;
        }
        return handle;
    }

    /// String-based spring API (hashes at call site).
    pub fn spring(self: *Self, id: []const u8, config: SpringConfig) SpringHandle {
        return self.springById(hashString(id), config);
    }

    // =========================================================================
    // Stagger Methods
    // =========================================================================

    /// Animate a single item within a stagger group.
    /// Call once per item per frame inside a list render loop.
    /// Each staggered item becomes a normal animation with a computed delay.
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

        var item_config = config.animation_config;
        item_config.delay_ms = config.animation_config.delay_ms + delay;

        return self.animateById(item_id, item_config);
    }

    /// String-based stagger API (hashes at call site).
    pub fn stagger(
        self: *Self,
        id: []const u8,
        index: u32,
        total_count: u32,
        config: StaggerConfig,
    ) AnimationHandle {
        return self.staggerById(hashString(id), index, total_count, config);
    }

    // =========================================================================
    // Motion Methods (tween-based)
    // =========================================================================

    /// Tween-based motion container. Manages enter/exit lifecycle automatically.
    /// Returns a MotionHandle with progress (0→1 on enter, 1→0 on exit) and
    /// a visible flag to gate rendering.
    pub fn motionById(self: *Self, motion_id: u32, show: bool, config: MotionConfig) MotionHandle {
        // Enforce pool limit
        if (self.motions.count() >= motion_mod.MAX_MOTIONS) {
            if (self.motions.getPtr(motion_id) == null) {
                return if (show) MotionHandle.shown else MotionHandle.hidden;
            }
        }

        const gop = self.motions.getOrPut(self.allocator, motion_id) catch {
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
                    AnimationState.init(self.io, enter_config)
                else
                    AnimationState.initSettled(enter_config, 0),
                .exit_state = AnimationState.initSettled(exit_config, 0),
                .enter_config = enter_config,
                .exit_config = exit_config,
            };
            // If entering on first mount, tick it immediately
            if (initial_phase == .entering) {
                const handle = motion_mod.tickMotion(self.io, gop.value_ptr, show);
                if (handle.phase == .entering or handle.phase == .exiting) {
                    self.active_motion_count += 1;
                }
                return handle;
            }
            return if (config.start_visible) MotionHandle.shown else MotionHandle.hidden;
        }

        const handle = motion_mod.tickMotion(self.io, gop.value_ptr, show);
        if (handle.phase == .entering or handle.phase == .exiting) {
            self.active_motion_count += 1;
        }
        return handle;
    }

    /// String-based tween motion API (hashes at call site).
    pub fn motion(self: *Self, id: []const u8, show: bool, config: MotionConfig) MotionHandle {
        return self.motionById(hashString(id), show, config);
    }

    // =========================================================================
    // Spring Motion Methods
    // =========================================================================

    /// Spring-based motion container. Interruptible enter/exit with velocity
    /// preservation. Target is set to 1.0 (show) or 0.0 (hide) automatically.
    pub fn springMotionById(self: *Self, motion_id: u32, show: bool, config: SpringMotionConfig) MotionHandle {
        // Enforce pool limit
        if (self.spring_motions.count() >= motion_mod.MAX_MOTIONS) {
            if (self.spring_motions.getPtr(motion_id) == null) {
                return if (show) MotionHandle.shown else MotionHandle.hidden;
            }
        }

        const gop = self.spring_motions.getOrPut(self.allocator, motion_id) catch {
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
                    spring_mod.SpringState.initSettled(self.io, spring_config)
                else
                    spring_mod.SpringState.init(self.io, spring_config),
            };
        }

        const handle = motion_mod.tickSpringMotion(self.io, gop.value_ptr, show);
        if (handle.phase == .entering or handle.phase == .exiting) {
            self.active_motion_count += 1;
        }
        return handle;
    }

    /// String-based spring motion API (hashes at call site).
    pub fn springMotion(self: *Self, id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
        return self.springMotionById(hashString(id), show, config);
    }

    // =========================================================================
    // Frame Lifecycle
    // =========================================================================

    pub fn beginFrame(self: *Self) void {
        self.active_animation_count = 0; // Reset - will be incremented as animations are queried
        self.active_spring_count = 0; // Reset - will be incremented as springs are queried
        self.active_motion_count = 0; // Reset - will be incremented as motions are queried
        self.frame_counter +%= 1;
    }

    pub fn endFrame(_: *Self) void {}
};
