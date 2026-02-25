//! Text shaping - converts text strings into positioned glyphs
//!
//! Provides both a simple shaper (works with any FontFace) and an interface
//! for complex platform-specific shaping (ligatures, kerning, RTL, etc.)

const std = @import("std");
const types = @import("types.zig");
const font_face = @import("font_face.zig");

pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const FontFace = font_face.FontFace;

/// Shaper interface for complex text shaping
/// Platform backends implement this for full Unicode support
pub const Shaper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        /// Full text shaping with ligatures, kerning, etc.
        shape: *const fn (ptr: *anyopaque, face: FontFace, text: []const u8, allocator: std.mem.Allocator) anyerror!ShapedRun,
        /// Release resources
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn shape(self: Shaper, face: FontFace, text: []const u8) !ShapedRun {
        return self.vtable.shape(self.ptr, face, text, self.allocator);
    }

    pub fn deinit(self: *Shaper) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};
