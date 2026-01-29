//! Accessibility (A11y) System
//!
//! Provides screen reader and assistive technology support for gooey applications.
//!
//! ## Architecture
//!
//! - **Tree**: Maintains a parallel accessibility tree mirroring the UI
//! - **Element**: Individual accessible elements with roles, names, and states
//! - **Bridge**: Platform-specific bridge to native accessibility APIs
//!
//! ## Platform Support
//!
//! - **macOS**: NSAccessibility protocol via mac_bridge
//! - **Linux**: AT-SPI2 D-Bus protocol via linux_bridge
//! - **Web**: ARIA attributes via web_bridge
//!
//! ## Usage
//!
//! ```zig
//! const a11y = @import("gooey").accessibility;
//!
//! // Create accessibility system
//! var accessibility = try a11y.Accessibility.init(allocator);
//! defer accessibility.deinit();
//!
//! // Register an element
//! const element = a11y.Element{
//!     .role = .button,
//!     .name = "Submit",
//!     .description = "Submit the form",
//! };
//! ```

const builtin = @import("builtin");

// =============================================================================
// Core Types
// =============================================================================

/// Main accessibility system coordinator
pub const Accessibility = @import("accessibility.zig").Accessibility;

/// Accessibility tree for tracking UI hierarchy
pub const Tree = @import("tree.zig").Tree;

/// Individual accessible element
pub const Element = @import("element.zig").Element;

/// Shared type definitions
pub const types = @import("types.zig");

/// Accessibility constants (roles, states, etc.)
pub const constants = @import("constants.zig");

// =============================================================================
// Bridge Interface
// =============================================================================

/// Platform bridge interface for native accessibility APIs
pub const bridge = @import("bridge.zig");
pub const Bridge = bridge.Bridge;
pub const NullBridge = bridge.NullBridge;
pub const TestBridge = bridge.TestBridge;

// =============================================================================
// Platform-Specific Bridges
// =============================================================================

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// macOS accessibility bridge (NSAccessibility)
pub const mac_bridge = if (!is_wasm and builtin.os.tag == .macos)
    @import("mac_bridge.zig")
else
    struct {};

/// Linux accessibility bridge (AT-SPI2 via D-Bus)
pub const linux_bridge = if (!is_wasm and builtin.os.tag == .linux)
    @import("linux_bridge.zig")
else
    struct {};

/// Web accessibility bridge (ARIA attributes)
pub const web_bridge = if (is_wasm)
    @import("web_bridge.zig")
else
    struct {};

// =============================================================================
// Utilities
// =============================================================================

/// Debug utilities for accessibility inspection
pub const debug = @import("debug.zig");

/// Element fingerprinting for change detection
pub const fingerprint = @import("fingerprint.zig");

// =============================================================================
// Re-exports for Convenience
// =============================================================================

/// Common role types
pub const Role = types.Role;

/// Common state flags
pub const State = types.State;
