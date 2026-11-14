//! Accessibility policy constants.
//!
//! Every capacity is in the app's budget (`ResourceLimits.a11y`, and
//! `build.box_depth_max` for nesting) and reaches the tree and bridges through
//! `tree.Capacity`; what remains here is policy, not storage.

/// Frames between screen reader activity checks.
/// Check every ~1 second at 60fps to avoid per-frame IPC.
pub const SCREEN_READER_CHECK_INTERVAL: u32 = 60;
