const builtin = @import("builtin");

pub const Accessibility = @import("accessibility.zig").Accessibility;

pub const Tree = @import("tree.zig").Tree;
pub const TreeCapacity = @import("tree.zig").Capacity;

pub const Element = @import("element.zig").Element;

pub const types = @import("types.zig");

pub const constants = @import("constants.zig");

pub const bridge = @import("bridge.zig");
pub const Bridge = bridge.Bridge;
pub const NullBridge = bridge.NullBridge;
pub const TestBridge = bridge.TestBridge;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub const mac_bridge = if (!is_wasm and builtin.os.tag == .macos)
    @import("mac_bridge.zig")
else
    struct {};

pub const web_bridge = if (is_wasm)
    @import("web_bridge.zig")
else
    struct {};

pub const windows_bridge = if (!is_wasm and builtin.os.tag == .windows)
    @import("windows_bridge.zig")
else
    struct {};

pub const debug = @import("debug.zig");

pub const fingerprint = @import("fingerprint.zig");

pub const Role = types.Role;

pub const State = types.State;

/// Live-region politeness: the type of `ui.A11y.live`.
pub const Live = types.Live;

/// Heading depth: the type of `ui.A11y.heading_level`.
pub const HeadingLevel = types.HeadingLevel;

/// A range's axis: the type of `ui.A11y.Range.orientation`.
pub const Orientation = types.Orientation;
