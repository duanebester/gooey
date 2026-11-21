//! Capacity policy here; storage is sized in `tree.Capacity` from the app's
//! `ResourceLimits.a11y` and reaches the tree and bridges through it.

/// Check every ~1 second at 60fps to avoid per-frame IPC.
pub const SCREEN_READER_CHECK_INTERVAL: u32 = 60;
