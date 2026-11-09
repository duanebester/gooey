//! Gooey Components
//!
//! Components on the 0.4.0 core, and the Lucide icon set.

const std = @import("std");

/// Lucide icon data for `Painter.svg`.
pub const Lucide = @import("lucide.zig").Lucide;

/// Components on the 0.4.0 core.
pub const core = @import("core/root.zig");

test {
    std.testing.refAllDecls(@This());
}
