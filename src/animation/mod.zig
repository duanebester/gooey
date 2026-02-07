//! Animation System
//!
//! Time-based interpolation for smooth UI transitions.
//!
//! - `Animation` (AnimationConfig) - Configuration for animation timing
//! - `AnimationHandle` - Current state of an animation (progress, running, etc.)
//! - `AnimationState` - Internal state tracking
//! - `Easing` - Easing functions (linear, easeIn, easeOut, etc.)
//! - `Duration` - Time duration type
//! - `lerp`, `lerpInt`, `lerpColor` - Interpolation helpers

const std = @import("std");

// =============================================================================
// Animation Module
// =============================================================================

pub const animation = @import("animation.zig");
pub const spring = @import("spring.zig");
pub const stagger = @import("stagger.zig");
pub const motion = @import("motion.zig");

// =============================================================================
// Core Types
// =============================================================================

pub const AnimationConfig = animation.AnimationConfig;
pub const Animation = AnimationConfig; // Alias for convenience
pub const AnimationHandle = animation.AnimationHandle;
pub const AnimationState = animation.AnimationState;
pub const AnimationId = animation.AnimationId;

// =============================================================================
// Timing
// =============================================================================

pub const Duration = animation.Duration;
pub const Easing = animation.Easing;
pub const EasingFn = animation.EasingFn;

// =============================================================================
// Interpolation Helpers
// =============================================================================

pub const lerp = animation.lerp;
pub const lerpInt = animation.lerpInt;
pub const lerpColor = animation.lerpColor;

// =============================================================================
// Spring Physics
// =============================================================================

pub const SpringConfig = spring.SpringConfig;
pub const SpringHandle = spring.SpringHandle;
pub const SpringState = spring.SpringState;

// =============================================================================
// Stagger Animations
// =============================================================================

pub const StaggerConfig = stagger.StaggerConfig;
pub const StaggerDirection = stagger.StaggerDirection;

// =============================================================================
// Motion Containers
// =============================================================================

pub const MotionConfig = motion.MotionConfig;
pub const MotionHandle = motion.MotionHandle;
pub const MotionPhase = motion.MotionPhase;
pub const MotionState = motion.MotionState;
pub const SpringMotionConfig = motion.SpringMotionConfig;
pub const SpringMotionState = motion.SpringMotionState;

// =============================================================================
// Internal
// =============================================================================

pub const calculateProgress = animation.calculateProgress;
pub const hashString = animation.hashString;
pub const computeTriggerHash = animation.computeTriggerHash;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
