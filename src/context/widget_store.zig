//! WidgetStore - Simple retained storage for stateful widgets
//!
//! Now includes animation state management.

const std = @import("std");
// PR 8.4b — the `TextInputState` / `TextAreaState` / `CodeEditorState`
// engine-type imports retired alongside the per-type StringHashMap
// fields and accessors. Storage lives on `Window.element_states`
// now (the keyed pool introduced in PR 8.1), keyed by
// `(EngineType, LayoutId.id)`. The two `Bounds` aliases were only
// used by the `default_*_bounds` fields that seeded the
// pre-PR-8.4b create-on-touch path; the pool's create-on-touch
// site (`Builder.renderInput` / `renderTextArea` / `renderCodeEditor`)
// computes bounds from layout output instead, so the defaults are
// gone too. Same retirement shape PR 8.4a used for
// `ScrollContainer` / `scroll_containers`.
const animation = @import("../animation/animation.zig");
const AnimationState = animation.AnimationState;
const AnimationConfig = animation.AnimationConfig;
const AnimationHandle = animation.AnimationHandle;
const AnimationId = animation.AnimationId;
const spring_mod = @import("../animation/spring.zig");
const SpringState = spring_mod.SpringState;
const SpringConfig = spring_mod.SpringConfig;
const SpringHandle = spring_mod.SpringHandle;
const stagger_mod = @import("../animation/stagger.zig");
const StaggerConfig = stagger_mod.StaggerConfig;
const motion_mod = @import("../animation/motion.zig");
const MotionConfig = motion_mod.MotionConfig;
const MotionHandle = motion_mod.MotionHandle;
const MotionPhase = motion_mod.MotionPhase;
const MotionState = motion_mod.MotionState;
const SpringMotionConfig = motion_mod.SpringMotionConfig;
const SpringMotionState = motion_mod.SpringMotionState;
const hashString = @import("../animation/animation.zig").hashString;
const change_tracker_mod = @import("change_tracker.zig");
const ChangeTracker = change_tracker_mod.ChangeTracker;

// PR 8.2 — `SelectState` and the `select_states: AutoHashMap(u32, SelectState)`
// field that used to live here have moved off `WidgetStore`. The state
// type is now declared in `components/select.zig` (the widget owns its
// own state struct), and the storage is the unified
// `Window.element_states` keyed pool. The four `*SelectState` accessors
// (`getOrCreateSelectState`, `getSelectState`, `closeSelectState`,
// `toggleSelectState`) were retired alongside the field — every former
// caller now goes through `window.element_states.withElementState`,
// `get`, or `remove` directly. This is the first slice of PR 8
// validating the pool's call-site shape on a real consumer; subsequent
// 8.x slices peel `text_input` / `text_area` / `code_editor` /
// `scroll_container` off `WidgetStore` the same way. See
// `docs/cleanup-implementation-plan.md` PR 8.2.

pub const WidgetStore = struct {
    allocator: std.mem.Allocator,
    /// IO instance for monotonic timing. Stored on the struct because
    /// animations sample the `awake` clock every frame and callers
    /// (e.g. `cx.animate`) come through methods, not free functions.
    /// `std.Io` is a pair of pointers into a process-lifetime vtable —
    /// safe and cheap to copy.
    io: std.Io,
    // PR 8.4b — `text_inputs` / `text_areas` / `code_editors`
    // StringHashMaps retired (lifted onto `Window.element_states`
    // keyed by `(EngineType, LayoutId.id)`). The matching
    // `accessed_this_frame` ptr-keyed set is also gone: it only
    // existed to bridge the StringHashMap key memory across frames,
    // and the pool keys directly on the layout-id hash with no duped
    // string. Same retirement shape PR 8.4a used for
    // `scroll_containers`.

    // PR 8.2 — `select_states` field retired. Select open/close state
    // lives on `Window.element_states` keyed by `(SelectState, id_hash)`
    // alongside every other element-attached state type.

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

    // Change detection (fixed-capacity, zero allocation after init)
    change_tracker: ChangeTracker = .{},

    const Self = @This();

    // =========================================================================
    // PR 8.4b — retired generic widget helpers
    // =========================================================================
    //
    // Pre-PR-8.4b this struct carried four `getOrCreateWidget` /
    // `removeWidget` / `getFocusedWidget` / `deinitWidgetMap` helpers
    // parameterised over `T ∈ { TextInputState, TextAreaState,
    // CodeEditorState }`. They mediated between the public
    // `textInput` / `textArea` / `codeEditor` accessors and the
    // per-type `StringHashMap(*T)` fields above. PR 8.4b retires the
    // maps onto `Window.element_states` (keyed by
    // `(T, LayoutId.id)`) and the helpers go with them — the pool's
    // own `getOrInsert` / `get` / `remove` cover all four shapes.
    // The focused-widget walk that `getFocusedWidget` previously did
    // is replaced in `runtime/input.zig` by per-pending-list lookups
    // (the focused widget rendered this frame, so its layout id is
    // in one of the `pending_*` lists).

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            // PR 8.4b — no per-type widget maps to init. Storage
            // lives on `Window.element_states` now (see field-block
            // comment above).
            // PR 8.2 — `select_states` field retired (lifted onto
            // `Window.element_states`). No init line here, no
            // matching `deinit` line below.
            .animations = .empty,
            .springs = .empty,
            .motions = .empty,
            .spring_motions = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        // PR 8.4b — the `deinitWidgetMap` calls for the three text
        // engine maps are gone; teardown now happens via
        // `Window.element_states.deinit()` walking the keyed-pool
        // entries through their type-erased deinit thunks. Same
        // path that handles `ScrollContainer` (PR 8.4a) and
        // `SelectState` (PR 8.2).
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
    // Frame Lifecycle
    // =========================================================================

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

    pub fn beginFrame(self: *Self) void {
        // PR 8.4b — `accessed_this_frame.clearRetainingCapacity()`
        // retired alongside the StringHashMap-keyed text widget maps;
        // there is no per-frame access set to reset on the pool
        // (slots persist until the widget calls `.remove` explicitly,
        // same retention semantics as `ScrollContainer` / `Select`).
        self.active_animation_count = 0; // Reset - will be incremented as animations are queried
        self.active_spring_count = 0; // Reset - will be incremented as springs are queried
        self.active_motion_count = 0; // Reset - will be incremented as motions are queried
        self.frame_counter +%= 1;
    }

    pub fn endFrame(_: *Self) void {}

    // =========================================================================
    // Text engine accessors retired in PR 8.4b
    // =========================================================================
    //
    // Pre-PR-8.4b this struct exposed a fan of accessors against the
    // three retired StringHashMaps:
    //
    //   * `textInput` / `textInputOrPanic` / `getTextInput` /
    //     `removeTextInput` / `hasTextInput` / `textInputCount` /
    //     `getFocusedTextInput`
    //   * `textArea` / `textAreaOrPanic` / `getTextArea` /
    //     `removeTextArea` / `getFocusedTextArea`
    //   * `codeEditor` / `codeEditorOrPanic` / `getCodeEditor` /
    //     `removeCodeEditor` / `getFocusedCodeEditor`
    //   * `blurAll` (walked all three maps and called `blur()` on every
    //     entry)
    //
    // All retired alongside the maps. The `*OrCreate*` shape moved
    // to `Window.element_states.getOrInsert(EngineType, layout_id.id,
    // EngineType.init(allocator, bounds))` (called from the
    // matching `Builder.render*` site, see `ui/builder.zig`); the
    // `get*` shape moved to `Window.element_states.get(EngineType,
    // layout_id.id)`; the `remove*` shape moved to
    // `Window.element_states.remove(EngineType, layout_id.id)`. The
    // `getFocused*` walk was replaced by
    // `runtime/input.zig::focusedTextInput` / `focusedTextArea` /
    // `focusedCodeEditor` (each iterates the matching `pending_*`
    // list, hits the pool by layout-id hash, and returns the first
    // `isFocused()` match). `blurAll` is no longer needed at this
    // layer — `Window.blurAll` now goes through the focus manager,
    // which already drives the focused widget's `.blur()` through
    // its `Focusable` vtable.
    //
    // The `ScrollContainer` accessors retired in PR 8.4a were
    // documented in the same shape; PR 8.4b removes the standalone
    // section and folds the rationale here. See
    // `docs/cleanup-implementation-plan.md` PR 8.4b for the full
    // call-site sweep.
    //
    // `hasTextInput` / `textInputCount` were unused outside their
    // own definitions and are retired without replacement — the pool
    // exposes `contains(S, id_hash)` and `len()` for callers who
    // need either signal.

    // =========================================================================
    // Select State (internal open/close for Select widgets)
    // =========================================================================
    //
    // PR 8.2 — the four `*SelectState` accessors that used to live
    // here (`getOrCreateSelectState` / `getSelectState` /
    // `closeSelectState` / `toggleSelectState`) have been retired.
    // `Select` is the first consumer of `Window.element_states`, the
    // unified keyed pool introduced in PR 8.1. Former callers now
    // route through `window.element_states.withElementState(SelectState,
    // id_hash, SelectState.defaultInit)` (open-or-create read),
    // `.get` (read-only peek), or `.remove` (explicit teardown). The
    // toggle/close helpers moved into `components/select.zig` next
    // to the widget itself — they are widget-specific control-flow
    // (mutate one bool through the borrowed `*SelectState`), not
    // framework-level storage policy. See
    // `docs/cleanup-implementation-plan.md` PR 8.2 for the full
    // call-site sweep.
};
