//! Core primitives for Gooey: resource limits, reservations, the fixed-capacity
//! array, custom shader descriptions, and compile-time interface checks.
//!
//! Geometry value types and path math live in `src/geometry/`.

const std = @import("std");

// =============================================================================
// Fixed-Capacity Array (static allocation container)
// =============================================================================

pub const fixed_array = @import("fixed_array.zig");
pub const FixedArray = fixed_array.FixedArray;

// =============================================================================
// Limits (static allocation bounds)
// =============================================================================

pub const limits = @import("limits.zig");

// =============================================================================
// Custom Shaders
// =============================================================================

pub const shader = @import("shader.zig");
pub const CustomShader = shader.CustomShader;

// =============================================================================
// Interface Verification (compile-time checks)
//
// Subsystem shapes only. The platform boundary (`Platform`, `PlatformWindow`)
// is verified by `src/platform/contract.zig` against complete function types.
// =============================================================================

pub const interface_verify = @import("interface_verify.zig");
pub const verifyRendererInterface = interface_verify.verifyRendererInterface;
pub const verifyClipboardInterface = interface_verify.verifyClipboardInterface;
pub const verifySvgRasterizerInterface = interface_verify.verifySvgRasterizerInterface;
pub const verifySvgRasterizerModule = interface_verify.verifySvgRasterizerModule;
pub const verifyImageLoaderInterface = interface_verify.verifyImageLoaderInterface;
pub const verifyImageLoaderModule = interface_verify.verifyImageLoaderModule;

pub const verifyFileDialogInterface = interface_verify.verifyFileDialogInterface;
pub const verifyFocusableInterface = interface_verify.verifyFocusableInterface;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
