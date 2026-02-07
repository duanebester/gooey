//! WidgetStore - Simple retained storage for stateful widgets
//!
//! Now includes animation state management.

const std = @import("std");
const TextInput = @import("../widgets/text_input_state.zig").TextInput;
const Bounds = @import("../widgets/text_input_state.zig").Bounds;
const ScrollContainer = @import("../widgets/scroll_container.zig").ScrollContainer;
const TextArea = @import("../widgets/text_area_state.zig").TextArea;
const TextAreaBounds = @import("../widgets/text_area_state.zig").Bounds;
const CodeEditorState = @import("../widgets/code_editor_state.zig").CodeEditorState;
const CodeEditorBounds = @import("../widgets/code_editor_state.zig").Bounds;
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

pub const WidgetStore = struct {
    allocator: std.mem.Allocator,
    text_inputs: std.StringHashMap(*TextInput),
    text_areas: std.StringHashMap(*TextArea),
    code_editors: std.StringHashMap(*CodeEditorState),
    scroll_containers: std.StringHashMap(*ScrollContainer),
    accessed_this_frame: std.StringHashMap(void),

    // u32-keyed animation storage
    animations: std.AutoArrayHashMap(u32, AnimationState),
    active_animation_count: u32 = 0,
    frame_counter: u64 = 1,

    // u32-keyed spring storage
    springs: std.AutoArrayHashMap(u32, SpringState),
    active_spring_count: u32 = 0,

    // u32-keyed motion storage (tween-based and spring-based)
    motions: std.AutoArrayHashMap(u32, MotionState),
    spring_motions: std.AutoArrayHashMap(u32, SpringMotionState),
    active_motion_count: u32 = 0,

    default_text_input_bounds: Bounds = .{ .x = 0, .y = 0, .width = 200, .height = 36 },
    default_text_area_bounds: TextAreaBounds = .{ .x = 0, .y = 0, .width = 300, .height = 150 },
    default_code_editor_bounds: CodeEditorBounds = .{ .x = 0, .y = 0, .width = 400, .height = 300 },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .text_inputs = std.StringHashMap(*TextInput).init(allocator),
            .text_areas = std.StringHashMap(*TextArea).init(allocator),
            .code_editors = std.StringHashMap(*CodeEditorState).init(allocator),
            .scroll_containers = std.StringHashMap(*ScrollContainer).init(allocator),
            .accessed_this_frame = std.StringHashMap(void).init(allocator),
            .animations = std.AutoArrayHashMap(u32, AnimationState).init(allocator),
            .springs = std.AutoArrayHashMap(u32, SpringState).init(allocator),
            .motions = std.AutoArrayHashMap(u32, MotionState).init(allocator),
            .spring_motions = std.AutoArrayHashMap(u32, SpringMotionState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up TextInputs
        var it = self.text_inputs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.text_inputs.deinit();

        // Clean up TextAreas
        var ta_it = self.text_areas.iterator();
        while (ta_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.text_areas.deinit();

        // Clean up CodeEditors
        var ce_it = self.code_editors.iterator();
        while (ce_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.code_editors.deinit();

        // Clean up ScrollContainers
        var sc_it = self.scroll_containers.iterator();
        while (sc_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.scroll_containers.deinit();

        // Clean up animation keys
        self.animations.deinit();

        // Clean up springs
        self.springs.deinit();

        // Clean up motions
        self.motions.deinit();
        self.spring_motions.deinit();

        self.accessed_this_frame.deinit();
    }

    // =========================================================================
    // Animation Methods (OPTIMIZED with u32 keys)
    // =========================================================================

    /// Get or create animation by hashed ID (no string allocation)
    pub fn animateById(self: *Self, anim_id: u32, config: AnimationConfig) AnimationHandle {
        const gop = self.animations.getOrPut(anim_id) catch {
            return AnimationHandle.complete;
        };

        if (!gop.found_existing) {
            gop.value_ptr.* = AnimationState.init(config);
            gop.value_ptr.last_queried_frame = self.frame_counter;
        } else if (!gop.value_ptr.running and self.frame_counter > gop.value_ptr.last_queried_frame + 1) {
            // Animation completed AND wasn't queried last frame (component was hidden).
            // Restart so mount/stagger animations replay on re-appearance.
            const gen = gop.value_ptr.generation +% 1;
            gop.value_ptr.* = AnimationState.init(config);
            gop.value_ptr.generation = gen;
            gop.value_ptr.last_queried_frame = self.frame_counter;
        } else {
            gop.value_ptr.last_queried_frame = self.frame_counter;
        }

        const handle = animation.calculateProgress(gop.value_ptr);
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
        const gop = self.animations.getOrPut(anim_id) catch {
            return AnimationHandle.complete;
        };

        // Always reset the animation state (whether existing or new)
        gop.value_ptr.* = AnimationState.init(config);
        gop.value_ptr.last_queried_frame = self.frame_counter;

        // If it was existing, preserve generation continuity
        if (gop.found_existing) {
            gop.value_ptr.generation +%= 1;
        }

        self.active_animation_count += 1;
        return animation.calculateProgress(gop.value_ptr);
    }

    /// String-based restart API
    pub fn restartAnimation(self: *Self, id: []const u8, config: AnimationConfig) AnimationHandle {
        return self.restartAnimationById(animation.hashString(id), config);
    }

    /// OPTIMIZED animateOn - single HashMap lookup!
    /// Trigger hash is now stored IN the AnimationState
    pub fn animateOnById(self: *Self, anim_id: u32, trigger_hash: u64, config: AnimationConfig) AnimationHandle {
        const platform_time = @import("../platform/mod.zig");

        const gop = self.animations.getOrPut(anim_id) catch {
            return AnimationHandle.complete;
        };

        if (gop.found_existing) {
            // Check if trigger changed
            if (gop.value_ptr.trigger_hash != trigger_hash) {
                // Trigger changed - restart animation and update hash
                gop.value_ptr.start_time = platform_time.time.milliTimestamp();
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

        const handle = animation.calculateProgress(gop.value_ptr);
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
            const handle = animation.calculateProgress(state);
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
                gop.value_ptr.last_time_ms = @import("../platform/mod.zig").time.milliTimestamp();
            }
        }

        const handle = spring_mod.tickSpring(gop.value_ptr);
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
                    AnimationState.init(enter_config)
                else
                    AnimationState.initSettled(enter_config, 0),
                .exit_state = AnimationState.initSettled(exit_config, 0),
                .enter_config = enter_config,
                .exit_config = exit_config,
            };
            // If entering on first mount, tick it immediately
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

    /// String-based spring motion API (hashes at call site).
    pub fn springMotion(self: *Self, id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
        return self.springMotionById(hashString(id), show, config);
    }

    pub fn beginFrame(self: *Self) void {
        self.accessed_this_frame.clearRetainingCapacity();
        self.active_animation_count = 0; // Reset - will be incremented as animations are queried
        self.active_spring_count = 0; // Reset - will be incremented as springs are queried
        self.active_motion_count = 0; // Reset - will be incremented as motions are queried
        self.frame_counter +%= 1;
    }

    pub fn endFrame(_: *Self) void {}

    // =========================================================================
    // TextInput (existing code)
    // =========================================================================

    pub fn textInput(self: *Self, id: []const u8) ?*TextInput {
        if (self.text_inputs.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const input = self.allocator.create(TextInput) catch return null;
        errdefer self.allocator.destroy(input);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(input);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        input.* = TextInput.initWithId(self.allocator, self.default_text_input_bounds, owned_key);

        self.text_inputs.put(owned_key, input) catch {
            input.deinit();
            self.allocator.destroy(input);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return input;
    }

    pub fn textInputOrPanic(self: *Self, id: []const u8) *TextInput {
        return self.textInput(id) orelse @panic("Failed to allocate TextInput");
    }

    // =========================================================================
    // TextArea
    // =========================================================================

    pub fn textArea(self: *Self, id: []const u8) ?*TextArea {
        if (self.text_areas.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const ta = self.allocator.create(TextArea) catch return null;
        errdefer self.allocator.destroy(ta);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(ta);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        ta.* = TextArea.initWithId(self.allocator, self.default_text_area_bounds, owned_key);

        self.text_areas.put(owned_key, ta) catch {
            ta.deinit();
            self.allocator.destroy(ta);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return ta;
    }

    pub fn textAreaOrPanic(self: *Self, id: []const u8) *TextArea {
        return self.textArea(id) orelse @panic("Failed to allocate TextArea");
    }

    pub fn getTextArea(self: *Self, id: []const u8) ?*TextArea {
        return self.text_areas.get(id);
    }

    pub fn removeTextArea(self: *Self, id: []const u8) void {
        if (self.text_areas.fetchRemove(id)) |kv| {
            _ = self.accessed_this_frame.remove(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    pub fn getFocusedTextArea(self: *Self) ?*TextArea {
        var it = self.text_areas.valueIterator();
        while (it.next()) |ta| {
            if (ta.*.isFocused()) {
                return ta.*;
            }
        }
        return null;
    }

    // =========================================================================
    // CodeEditor
    // =========================================================================

    pub fn codeEditor(self: *Self, id: []const u8) ?*CodeEditorState {
        if (self.code_editors.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const ce = self.allocator.create(CodeEditorState) catch return null;
        errdefer self.allocator.destroy(ce);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(ce);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        ce.* = CodeEditorState.initWithId(self.allocator, self.default_code_editor_bounds, owned_key);

        self.code_editors.put(owned_key, ce) catch {
            ce.deinit();
            self.allocator.destroy(ce);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return ce;
    }

    pub fn codeEditorOrPanic(self: *Self, id: []const u8) *CodeEditorState {
        return self.codeEditor(id) orelse @panic("Failed to allocate CodeEditorState");
    }

    pub fn getCodeEditor(self: *Self, id: []const u8) ?*CodeEditorState {
        return self.code_editors.get(id);
    }

    pub fn removeCodeEditor(self: *Self, id: []const u8) void {
        if (self.code_editors.fetchRemove(id)) |kv| {
            _ = self.accessed_this_frame.remove(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    pub fn getFocusedCodeEditor(self: *Self) ?*CodeEditorState {
        var it = self.code_editors.valueIterator();
        while (it.next()) |ce| {
            if (ce.*.isFocused()) {
                return ce.*;
            }
        }
        return null;
    }

    // =========================================================================
    // ScrollContainer (existing)
    // =========================================================================

    pub fn scrollContainer(self: *Self, id: []const u8) ?*ScrollContainer {
        if (self.scroll_containers.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const sc = self.allocator.create(ScrollContainer) catch return null;
        errdefer self.allocator.destroy(sc);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(sc);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        sc.* = ScrollContainer.init(self.allocator, owned_key);

        self.scroll_containers.put(owned_key, sc) catch {
            sc.deinit();
            self.allocator.destroy(sc);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return sc;
    }

    pub fn getScrollContainer(self: *Self, id: []const u8) ?*ScrollContainer {
        return self.scroll_containers.get(id);
    }

    // =========================================================================
    // TextInput helpers (existing)
    // =========================================================================

    pub fn removeTextInput(self: *Self, id: []const u8) void {
        if (self.text_inputs.fetchRemove(id)) |kv| {
            _ = self.accessed_this_frame.remove(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    pub fn getTextInput(self: *Self, id: []const u8) ?*TextInput {
        return self.text_inputs.get(id);
    }

    pub fn hasTextInput(self: *Self, id: []const u8) bool {
        return self.text_inputs.contains(id);
    }

    pub fn textInputCount(self: *Self) usize {
        return self.text_inputs.count();
    }

    pub fn getFocusedTextInput(self: *Self) ?*TextInput {
        var it = self.text_inputs.valueIterator();
        while (it.next()) |input| {
            if (input.*.isFocused()) {
                return input.*;
            }
        }
        return null;
    }

    pub fn focusTextInput(self: *Self, id: []const u8) void {
        if (self.getFocusedTextInput()) |current| {
            current.blur();
        }
        if (self.text_inputs.get(id)) |input| {
            input.focus();
        }
    }

    pub fn blurAll(self: *Self) void {
        var it = self.text_inputs.valueIterator();
        while (it.next()) |input| {
            input.*.blur();
        }
        var ta_it = self.text_areas.valueIterator();
        while (ta_it.next()) |ta| {
            ta.*.blur();
        }
        var ce_it = self.code_editors.valueIterator();
        while (ce_it.next()) |ce| {
            ce.*.blur();
        }
    }
};
