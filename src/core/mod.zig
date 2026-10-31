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
// Backend contracts (0.4.0 core, contract §9)
// =============================================================================

pub const backend = @import("backend.zig");

// =============================================================================
// The 0.4.0 core (contract "Shape"): runs beside the 0.3.1 middle until
// phase 6. `root.zig` is its public surface.
// =============================================================================

const surface = @import("root.zig");
pub const App = surface.App;
pub const Config = surface.Config;
pub const Cx = surface.Cx;
pub const ui = surface.ui;
pub const Handler = surface.Handler;
pub const Effects = surface.Effects;
pub const PathPromptOptions = surface.PathPromptOptions;
pub const SavePromptOptions = surface.SavePromptOptions;
pub const Paths = surface.Paths;
pub const Entity = surface.Entity;
pub const ElementId = surface.ElementId;
pub const Key = surface.Key;
pub const Lifetime = surface.Lifetime;
pub const Handle = surface.Handle;
pub const Query = surface.Query;
pub const Theme = surface.Theme;
pub const Painter = surface.Painter;
pub const InputEngine = surface.InputEngine;
pub const AreaEngine = surface.AreaEngine;
pub const ResourceLimits = surface.ResourceLimits;
pub const FontLimits = surface.FontLimits;
pub const FontSource = surface.FontSource;
pub const internals = surface;

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
    _ = @import("root.zig");
}
