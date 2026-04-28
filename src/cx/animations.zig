//! `cx.animations` — animation, spring, stagger, and motion APIs.
//!
//! This module hosts the bodies of the animation helpers that used to
//! live directly on `Cx`. They are accessed through the
//! `cx.animations.<name>(...)` sub-namespace, which is implemented as a
//! zero-sized field on `Cx` whose methods recover `*Cx` via
//! `@fieldParentPtr`. That keeps the call shape free of extra
//! parentheses while moving ~200 lines of animation-specific code out
//! of `cx.zig`.
//!
//! ## Why "animations" and not "animate"?
//!
//! Zig fields and decls share a namespace, so a field named `animate`
//! on `Cx` would collide with the existing `cx.animate(id, config)`
//! method. The plural `animations` reads naturally as a noun
//! (CLAUDE.md §9 — "Nouns compose better than adjectives or
//! participles") and avoids the collision until the deprecated
//! top-level forwarders are removed in PR 9.
//!
//! The original top-level methods (`cx.animate`, `cx.spring`,
//! `cx.stagger`, `cx.motion`, `cx.springMotion`, and their `*Comptime`
//! variants) remain as deprecated one-line forwarders into this
//! module — they will be removed in PR 9.
//!
//! ## Naming inside the namespace
//!
//! The redundant prefix is dropped now that the namespace carries the
//! grouping. `cx.animateComptime` becomes `cx.animations.tweenComptime`
//! / `cx.animations.tween` etc — but to keep the diff small for PR 5,
//! the names match the originals minus the `animate` prefix where it
//! was redundant:
//!
//! | Old                              | New                                       |
//! | -------------------------------- | ----------------------------------------- |
//! | `cx.animate(id, cfg)`            | `cx.animations.tween(id, cfg)`            |
//! | `cx.animateComptime(id, cfg)`    | `cx.animations.tweenComptime(id, cfg)`    |
//! | `cx.animateOn(id, t, cfg)`       | `cx.animations.tweenOn(id, t, cfg)`       |
//! | `cx.animateOnComptime(...)`      | `cx.animations.tweenOnComptime(...)`      |
//! | `cx.restartAnimation(id, cfg)`   | `cx.animations.restart(id, cfg)`          |
//! | `cx.restartAnimationComptime(.)` | `cx.animations.restartComptime(...)`      |
//! | `cx.spring(id, cfg)`             | `cx.animations.spring(id, cfg)`           |
//! | `cx.springComptime(id, cfg)`     | `cx.animations.springComptime(id, cfg)`   |
//! | `cx.stagger(...)`                | `cx.animations.stagger(...)`              |
//! | `cx.staggerComptime(...)`        | `cx.animations.staggerComptime(...)`      |
//! | `cx.motion(id, show, cfg)`       | `cx.animations.motion(id, show, cfg)`     |
//! | `cx.motionComptime(...)`         | `cx.animations.motionComptime(...)`       |
//! | `cx.springMotion(...)`           | `cx.animations.springMotion(...)`         |
//! | `cx.springMotionComptime(...)`   | `cx.animations.springMotionComptime(...)` |

const std = @import("std");

const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;

const animation_mod = @import("../animation/mod.zig");
const Animation = animation_mod.AnimationConfig;
const AnimationHandle = animation_mod.AnimationHandle;

const spring_mod = @import("../animation/spring.zig");
const SpringConfig = spring_mod.SpringConfig;
const SpringHandle = spring_mod.SpringHandle;

const stagger_mod = @import("../animation/stagger.zig");
const StaggerConfig = stagger_mod.StaggerConfig;

const motion_mod = @import("../animation/motion.zig");
const MotionConfig = motion_mod.MotionConfig;
const MotionHandle = motion_mod.MotionHandle;
const SpringMotionConfig = motion_mod.SpringMotionConfig;

/// Zero-sized namespace marker. Lives as the `animations` field on
/// `Cx` and recovers the parent context via `@fieldParentPtr` from
/// each method. See `lists.zig` for the rationale (CLAUDE.md §10 —
/// don't take aliases).
pub const Animations = struct {
    /// Force this ZST to inherit `Cx`'s alignment via a zero-byte
    /// `[0]usize` filler — see the matching note in `cx/lists.zig`
    /// for the rationale. Without this, the namespace field would
    /// limit `Cx`'s overall alignment to 1 and `@fieldParentPtr`
    /// would fail to compile with "increases pointer alignment".
    _align: [0]usize = .{},

    /// Recover the owning `*Cx` from this namespace field.
    inline fn cx(self: *Animations) *Cx {
        return @fieldParentPtr("animations", self);
    }

    // =========================================================================
    // Tween animations (formerly `cx.animate*`)
    // =========================================================================

    /// Tween animation with compile-time string hashing. Most efficient
    /// for string literals — the hash is computed at compile time.
    pub fn tweenComptime(
        self: *Animations,
        comptime id: []const u8,
        config: Animation,
    ) AnimationHandle {
        const anim_id = comptime animation_mod.hashString(id);
        return self.cx()._gooey.widgets.animateById(anim_id, config);
    }

    /// Tween animation with a runtime string id. Use this when the id
    /// is computed at runtime (e.g. per-row animations in a list).
    pub fn tween(
        self: *Animations,
        id: []const u8,
        config: Animation,
    ) AnimationHandle {
        std.debug.assert(id.len > 0);
        return self.cx()._gooey.widgets.animate(id, config);
    }

    /// Restart a tween animation with comptime id hashing. The
    /// animation is reset to the start regardless of its current
    /// progress.
    pub fn restartComptime(
        self: *Animations,
        comptime id: []const u8,
        config: Animation,
    ) AnimationHandle {
        const anim_id = comptime animation_mod.hashString(id);
        return self.cx()._gooey.widgets.restartAnimationById(anim_id, config);
    }

    /// Restart a tween animation with a runtime string id.
    pub fn restart(
        self: *Animations,
        id: []const u8,
        config: Animation,
    ) AnimationHandle {
        std.debug.assert(id.len > 0);
        return self.cx()._gooey.widgets.restartAnimation(id, config);
    }

    /// Restart-on-trigger tween with comptime id hashing. The
    /// animation restarts whenever `trigger`'s hash changes, making
    /// this the natural fit for animations driven by state changes.
    pub fn tweenOnComptime(
        self: *Animations,
        comptime id: []const u8,
        trigger: anytype,
        config: Animation,
    ) AnimationHandle {
        const anim_id = comptime animation_mod.hashString(id);
        const trigger_hash = computeTriggerHash(@TypeOf(trigger), trigger);
        return self.cx()._gooey.widgets.animateOnById(anim_id, trigger_hash, config);
    }

    /// Restart-on-trigger tween with a runtime string id.
    pub fn tweenOn(
        self: *Animations,
        id: []const u8,
        trigger: anytype,
        config: Animation,
    ) AnimationHandle {
        std.debug.assert(id.len > 0);
        const trigger_hash = computeTriggerHash(@TypeOf(trigger), trigger);
        return self.cx()._gooey.widgets.animateOn(id, trigger_hash, config);
    }

    // =========================================================================
    // Spring animations
    // =========================================================================

    /// Declarative spring with comptime id hashing. Set the target
    /// every frame; the spring smoothly tracks it, inheriting velocity
    /// on interruption — that's the property that makes springs feel
    /// "alive" compared to tweens.
    ///
    /// ```zig
    /// const s = cx.animations.springComptime("panel-height", .{
    ///     .target = if (expanded) 1.0 else 0.0,
    ///     .stiffness = 200,
    ///     .damping = 20,
    /// });
    /// const height = lerp(0.0, 300.0, s.clamped());
    /// ```
    pub fn springComptime(
        self: *Animations,
        comptime id: []const u8,
        config: SpringConfig,
    ) SpringHandle {
        const spring_id = comptime animation_mod.hashString(id);
        return self.cx()._gooey.widgets.springById(spring_id, config);
    }

    /// Declarative spring with a runtime string id.
    pub fn spring(
        self: *Animations,
        id: []const u8,
        config: SpringConfig,
    ) SpringHandle {
        std.debug.assert(id.len > 0);
        return self.cx()._gooey.widgets.spring(id, config);
    }

    // =========================================================================
    // Stagger animations
    // =========================================================================

    /// Staggered animation for list items with comptime id hashing.
    /// Each item gets its own animation with a computed delay based on
    /// its index and the stagger direction.
    ///
    /// ```zig
    /// for (items, 0..) |item, i| {
    ///     const anim = cx.animations.staggerComptime(
    ///         "list-enter",
    ///         @intCast(i),
    ///         @intCast(items.len),
    ///         .list,
    ///     );
    ///     cx.render(ui.box(.{
    ///         .background = Color.white.withAlpha(anim.progress),
    ///     }, .{ ui.text(item.name, .{}) }));
    /// }
    /// ```
    pub fn staggerComptime(
        self: *Animations,
        comptime id: []const u8,
        index: u32,
        total_count: u32,
        config: StaggerConfig,
    ) AnimationHandle {
        std.debug.assert(index <= total_count);
        const base_id = comptime animation_mod.hashString(id);
        return self.cx()._gooey.widgets.staggerById(base_id, index, total_count, config);
    }

    /// Staggered animation for list items with a runtime string id.
    pub fn stagger(
        self: *Animations,
        id: []const u8,
        index: u32,
        total_count: u32,
        config: StaggerConfig,
    ) AnimationHandle {
        std.debug.assert(id.len > 0);
        std.debug.assert(index <= total_count);
        return self.cx()._gooey.widgets.stagger(id, index, total_count, config);
    }

    // =========================================================================
    // Motion containers (tween-based)
    // =========================================================================

    /// Tween-based motion container with comptime id hashing. Manages
    /// enter/exit lifecycle so callers can keep rendering during the
    /// exit transition.
    ///
    /// ```zig
    /// const m = cx.animations.motionComptime("panel", show_panel, .fade);
    /// if (m.visible) {
    ///     cx.render(ui.box(.{
    ///         .background = Color.blue.withAlpha(m.progress),
    ///     }, .{ /* ... */ }));
    /// }
    /// ```
    pub fn motionComptime(
        self: *Animations,
        comptime id: []const u8,
        show: bool,
        config: MotionConfig,
    ) MotionHandle {
        const mid = comptime animation_mod.hashString(id);
        return self.cx()._gooey.widgets.motionById(mid, show, config);
    }

    /// Tween-based motion container with a runtime string id.
    pub fn motion(
        self: *Animations,
        id: []const u8,
        show: bool,
        config: MotionConfig,
    ) MotionHandle {
        std.debug.assert(id.len > 0);
        return self.cx()._gooey.widgets.motion(id, show, config);
    }

    // =========================================================================
    // Spring motion containers
    // =========================================================================

    /// Spring-based motion container with comptime id hashing.
    /// Interruptible enter/exit — toggling `show` mid-transition
    /// preserves spring velocity, matching the behavior of standalone
    /// `springComptime`.
    ///
    /// ```zig
    /// const m = cx.animations.springMotionComptime("modal", show_modal, .bouncy);
    /// if (m.visible) {
    ///     cx.render(ui.box(.{
    ///         .width = lerp(0.0, 400.0, m.progress),
    ///     }, .{ /* ... */ }));
    /// }
    /// ```
    pub fn springMotionComptime(
        self: *Animations,
        comptime id: []const u8,
        show: bool,
        config: SpringMotionConfig,
    ) MotionHandle {
        const mid = comptime animation_mod.hashString(id);
        return self.cx()._gooey.widgets.springMotionById(mid, show, config);
    }

    /// Spring-based motion container with a runtime string id.
    pub fn springMotion(
        self: *Animations,
        id: []const u8,
        show: bool,
        config: SpringMotionConfig,
    ) MotionHandle {
        std.debug.assert(id.len > 0);
        return self.cx()._gooey.widgets.springMotion(id, show, config);
    }
};

// =============================================================================
// Helpers
// =============================================================================

/// Compute a hash for any trigger value for use with `tweenOn` /
/// `tweenOnComptime`. Uses type-specific handling for booleans and
/// enums so triggers compare structurally rather than via their
/// underlying byte representation. This must stay in sync with the
/// implementation in `cx.zig` while the deprecated forwarders exist —
/// PR 9 will remove the duplicate.
fn computeTriggerHash(comptime T: type, value: T) u64 {
    const info = @typeInfo(T);
    if (info == .bool) return if (value) 1 else 0;
    if (info == .@"enum") return @intFromEnum(value);
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&value));
}
