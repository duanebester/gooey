//! Event propagation primitives
//!
//! `EventPhase` and `EventResult` describe how events travel through the
//! dispatch tree (see `context/dispatch.zig`):
//! 1. Capture: root -> target (top-down)
//! 2. Target: the event has reached its target node
//! 3. Bubble: target -> root (bottom-up)
//!
//! This matches the DOM event model and lets parent nodes intercept events
//! before children see them (capture) or handle events children didn't
//! consume (bubble).

/// Result of handling an event
pub const EventResult = enum {
    /// Event was not handled, continue propagation
    ignored,
    /// Event was handled, but allow propagation to continue
    handled,
    /// Event was handled, stop all propagation
    stop,
};

/// Phase of event propagation
pub const EventPhase = enum {
    /// Event is traveling down from root to target
    capture,
    /// Event has reached the target element
    target,
    /// Event is traveling up from target to root
    bubble,
};
