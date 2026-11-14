//! Gooey Accessibility (A11Y) Module
//!
//! Provides semantic accessibility information for platform screen readers
//! and assistive technologies. Built on immediate-mode principles with
//! fingerprint-based identity for cross-frame correlation.
//!
//! Design principles:
//! - Zero allocation after init (pools sized from `ResourceLimits.a11y`)
//! - Fingerprint stability across identical frames
//! - Platform-agnostic tree with pluggable bridges
//!
//! Usage:
//! ```
//! const a11y = @import("accessibility/accessibility.zig");
//!
//! var tree: a11y.Tree = undefined;
//! try tree.initInPlace(&a11y.TreeCapacity.fromLimits(&limits));
//! defer tree.deinit();
//! tree.beginFrame();
//!
//! _ = tree.pushElement(.{
//!     .role = .button,
//!     .name = "Submit",
//!     .state = .{ .focused = true },
//! });
//! tree.popElement();
//!
//! tree.endFrame();
//! ```

const std = @import("std");
const builtin = @import("builtin");

// Enable verbose init logging for debugging stack overflow issues
const verbose_init_logging = false;

// WASM debug logging (no-op on native, or when verbose logging disabled)
const wasm_log = if (builtin.os.tag == .freestanding and verbose_init_logging)
    struct {
        const web_imports = @import("../platform/web/imports.zig");
        pub fn log(comptime fmt: []const u8, args: anytype) void {
            web_imports.log(fmt, args);
        }
    }
else
    struct {
        pub fn log(comptime fmt: []const u8, args: anytype) void {
            _ = fmt;
            _ = args;
        }
    };

// Core types
pub const constants = @import("constants.zig");
pub const types = @import("types.zig");
pub const fingerprint = @import("fingerprint.zig");
pub const element = @import("element.zig");
pub const tree = @import("tree.zig");
pub const bridge = @import("bridge.zig");
pub const debug = @import("debug.zig");

// Platform bridges
pub const mac_bridge = if (builtin.os.tag == .macos) @import("mac_bridge.zig") else struct {};
pub const web_bridge = if (builtin.os.tag == .freestanding) @import("web_bridge.zig") else struct {};
pub const windows_bridge = if (builtin.os.tag == .windows)
    @import("windows_bridge.zig")
else
    struct {};

// Re-export commonly used types at top level
pub const Role = types.Role;
pub const State = types.State;
pub const Live = types.Live;
pub const HeadingLevel = types.HeadingLevel;

pub const Fingerprint = fingerprint.Fingerprint;
pub const computeFingerprint = fingerprint.compute;

pub const Element = element.Element;

pub const Tree = tree.Tree;
pub const TreeCapacity = tree.Capacity;
pub const ElementConfig = tree.ElementConfig;

pub const Bridge = bridge.Bridge;
pub const NullBridge = bridge.NullBridge;
pub const TestBridge = bridge.TestBridge;

// Platform-specific bridge types
pub const MacBridge = if (builtin.os.tag == .macos) mac_bridge.MacBridge else void;
pub const WebBridge = if (builtin.os.tag == .freestanding) web_bridge.WebBridge else void;
pub const WindowsBridge = if (builtin.os.tag == .windows) windows_bridge.WindowsBridge else void;

// Integration tests
const integration_test = @import("integration_test.zig");

/// Platform bridge storage union - only one platform bridge is active at a time.
/// Use `createPlatformBridge()` to initialize the appropriate bridge.
pub const PlatformBridge = union(enum) {
    mac: if (builtin.os.tag == .macos) MacBridge else void,
    web: if (builtin.os.tag == .freestanding) WebBridge else void,
    windows: if (builtin.os.tag == .windows) WindowsBridge else void,
    null_bridge: void,
};

/// Create the appropriate platform bridge for the current OS.
/// On macOS: Creates MacBridge with VoiceOver support
/// On Windows: Creates WindowsBridge with UI Automation support
/// On other platforms, Linux included, creates NullBridge (no-op): Linux
/// AT-SPI is shelved past 0.4.0 (contract decision 12).
///
/// Parameters:
///   element_count_max: the tree's `a11y.element_count_max`, which sizes the
///     bridge's element slots
///   window: Platform window object (objc.Object on macOS, the window's
///     `uia.Host` on Windows, ignored on others)
///   view: Platform view object for coordinate conversion (objc.Object on macOS, ignored on others)
///
/// Returns a Bridge interface that can be used platform-agnostically.
/// Marked noinline to prevent stack accumulation in WASM builds.
pub noinline fn createPlatformBridge(
    platform_bridge: *PlatformBridge,
    element_count_max: u16,
    window: anytype,
    view: anytype,
) Bridge {
    std.debug.assert(element_count_max > 0);
    if (builtin.os.tag == .macos) {
        platform_bridge.* = .{ .mac = MacBridge.init(element_count_max, window, view) };
        return platform_bridge.mac.bridge();
    } else if (builtin.os.tag == .windows) {
        platform_bridge.* = .{ .windows = WindowsBridge.init(element_count_max, window) };
        return platform_bridge.windows.bridge();
    } else if (builtin.os.tag == .freestanding) {
        platform_bridge.* = .{ .web = .{} };
        platform_bridge.web.assumed_active = true;
        platform_bridge.web.init(element_count_max);
        return platform_bridge.web.bridge();
    } else {
        platform_bridge.* = .{ .null_bridge = {} };
        return NullBridge.bridge();
    }
}

test {
    // Run all sub-module tests
    std.testing.refAllDecls(@This());
    // Run integration tests
    _ = integration_test;
}

test "platform bridge creation" {
    var platform_bridge: PlatformBridge = undefined;
    const capacity = TreeCapacity.standard;
    const b = createPlatformBridge(&platform_bridge, capacity.element_count_max, null, null);

    // Bridge should be usable regardless of platform
    var t: Tree = undefined;
    try t.initInPlace(&capacity);
    defer t.deinit();
    t.beginFrame();
    _ = t.pushElement(.{ .role = .button, .name = "Test" });
    t.popElement();
    t.endFrame();

    // These should all be safe no-ops when VoiceOver isn't running
    b.syncDirty(&t, t.getDirtyElements());
    b.removeElements(t.getRemovedFingerprints());
    b.announce("Test", .polite);
    b.focusChanged(&t, null);
    b.deinit();
}
