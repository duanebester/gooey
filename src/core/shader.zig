//! Custom Shader Types - Cross-platform shader definitions
//!
//! Provides a unified API for custom post-processing shaders that work
//! across different backends:
//! - macOS: MSL (Metal Shading Language)
//! - Web: WGSL (WebGPU Shading Language)
//!
//! Example:
//! ```zig
//! const plasma = CustomShader{
//!     .msl = @embedFile("shaders/plasma.msl"),
//!     .wgsl = @embedFile("shaders/plasma.wgsl"),
//! };
//!
//! // In App config:
//! .custom_shaders = &.{plasma},
//! ```

const builtin = @import("builtin");

/// Cross-platform custom shader definition
///
/// Contains shader source code for each supported backend.
/// At compile time, only the relevant backend's shader is used.
pub const CustomShader = struct {
    /// Metal Shading Language source (macOS)
    /// Uses Shadertoy-compatible mainImage signature
    msl: ?[]const u8 = null,

    /// WebGPU Shading Language source (Web)
    /// Uses Shadertoy-compatible mainImage signature
    wgsl: ?[]const u8 = null,

    /// Create a shader from MSL source only (macOS-only shader)
    pub fn fromMSL(source: []const u8) CustomShader {
        return .{ .msl = source };
    }

    /// Create a shader from WGSL source only (web-only shader)
    pub fn fromWGSL(source: []const u8) CustomShader {
        return .{ .wgsl = source };
    }

    /// Check if shader has source for current platform
    pub fn hasSourceForPlatform(self: CustomShader) bool {
        const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
        if (is_wasm) {
            return self.wgsl != null;
        } else {
            return self.msl != null;
        }
    }

    /// Get shader source for current platform, or null if not available
    pub fn getSourceForPlatform(self: CustomShader) ?[]const u8 {
        const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
        if (is_wasm) {
            return self.wgsl;
        } else {
            return self.msl;
        }
    }
};
