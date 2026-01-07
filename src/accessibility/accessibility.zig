//! Gooey Accessibility (A11Y) Module
//!
//! Provides semantic accessibility information for platform screen readers
//! and assistive technologies. Built on immediate-mode principles with
//! fingerprint-based identity for cross-frame correlation.
//!
//! Design principles:
//! - Zero allocation after init (static pools)
//! - Fingerprint stability across identical frames
//! - Platform-agnostic tree with pluggable bridges
//!
//! Usage:
//! ```
//! const a11y = @import("accessibility/accessibility.zig");
//!
//! var tree = a11y.Tree.init();
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
        const web_imports = @import("../platform/wgpu/web/imports.zig");
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

// Platform bridges (Phase 2+)
pub const mac_bridge = if (builtin.os.tag == .macos) @import("mac_bridge.zig") else struct {};
pub const linux_bridge = if (builtin.os.tag == .linux) @import("linux_bridge.zig") else struct {};
pub const web_bridge = if (builtin.os.tag == .freestanding) @import("web_bridge.zig") else struct {};

// Re-export commonly used types at top level
pub const Role = types.Role;
pub const State = types.State;
pub const Live = types.Live;
pub const HeadingLevel = types.HeadingLevel;

pub const Fingerprint = fingerprint.Fingerprint;
pub const computeFingerprint = fingerprint.compute;

pub const Element = element.Element;

pub const Tree = tree.Tree;
pub const ElementConfig = tree.ElementConfig;

pub const Bridge = bridge.Bridge;
pub const NullBridge = bridge.NullBridge;
pub const TestBridge = bridge.TestBridge;

// Platform-specific bridge types
pub const MacBridge = if (builtin.os.tag == .macos) mac_bridge.MacBridge else void;
pub const LinuxBridge = if (builtin.os.tag == .linux) linux_bridge.LinuxBridge else void;
pub const WebBridge = if (builtin.os.tag == .freestanding) web_bridge.WebBridge else void;

// Integration tests (Phase 1)
const integration_test = @import("integration_test.zig");

// Constants re-exported for convenience
pub const MAX_ELEMENTS = constants.MAX_ELEMENTS;
pub const MAX_DEPTH = constants.MAX_DEPTH;
pub const MAX_ANNOUNCEMENTS = constants.MAX_ANNOUNCEMENTS;

/// Platform bridge storage union - only one platform bridge is active at a time.
/// Use `createPlatformBridge()` to initialize the appropriate bridge.
pub const PlatformBridge = union(enum) {
    mac: if (builtin.os.tag == .macos) MacBridge else void,
    linux: if (builtin.os.tag == .linux) LinuxBridge else void,
    web: if (builtin.os.tag == .freestanding) WebBridge else void,
    null_bridge: void,
};

/// Create the appropriate platform bridge for the current OS.
/// On macOS: Creates MacBridge with VoiceOver support
/// On other platforms: Creates NullBridge (no-op)
///
/// Parameters:
///   window: Platform window object (objc.Object on macOS, ignored on others)
///   view: Platform view object for coordinate conversion (objc.Object on macOS, ignored on others)
///
/// Returns a Bridge interface that can be used platform-agnostically.
/// Marked noinline to prevent stack accumulation in WASM builds.
pub noinline fn createPlatformBridge(
    platform_bridge: *PlatformBridge,
    window: anytype,
    view: anytype,
) Bridge {
    if (builtin.os.tag == .macos) {
        platform_bridge.* = .{ .mac = MacBridge.init(window, view) };
        return platform_bridge.mac.bridge();
    } else if (builtin.os.tag == .linux) {
        platform_bridge.* = .{ .linux = LinuxBridge.init() };
        return platform_bridge.linux.bridge();
    } else if (builtin.os.tag == .freestanding) {
        // Web/WASM: field-by-field init avoids ~26KB stack temp from struct literal
        platform_bridge.* = .{ .web = undefined };
        @memset(std.mem.asBytes(&platform_bridge.web), 0);
        platform_bridge.web.assumed_active = true;
        platform_bridge.web.init();
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
    const b = createPlatformBridge(&platform_bridge, null, null);

    // Bridge should be usable regardless of platform
    var t = Tree.init();
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
