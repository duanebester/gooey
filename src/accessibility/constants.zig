//! Accessibility constants - hard limits per CLAUDE.md
//!
//! "Put a limit on everything" - these bounds prevent runaway
//! allocation and provide static sizing for all pools.

/// Maximum elements in the accessibility tree per frame.
/// Typical complex UI: 200-500 elements. 2048 allows headroom.
pub const MAX_ELEMENTS: u16 = 2048;

/// Maximum depth of element nesting (parent stack during build).
/// Matches dispatch tree depth for consistency.
pub const MAX_DEPTH: u8 = 64;

/// Maximum pending announcements per frame.
/// Most UIs announce 0-2 things per interaction.
pub const MAX_ANNOUNCEMENTS: u8 = 8;

/// Maximum relationships per element (labelledby, describedby, etc.)
pub const MAX_RELATIONS: u8 = 4;

/// Frames between screen reader activity checks.
/// Check every ~1 second at 60fps to avoid per-frame IPC.
pub const SCREEN_READER_CHECK_INTERVAL: u32 = 60;

/// Maximum dirty elements to sync per frame.
/// If exceeded, sync is spread across multiple frames.
pub const MAX_DIRTY_SYNC_PER_FRAME: u16 = 64;
