//! Text Rendering Debug Utilities
//!
//! Provides debug logging and comparison utilities for diagnosing text rendering
//! issues between native (CoreText) and web (Canvas2D) backends.
//!
//! Usage:
//!   const debug = @import("text_debug.zig");
//!   debug.logShapedRun("Tell", shaped_run);
//!   debug.logGlyphMetrics(text_system, 'T');

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/mod.zig");
const types = @import("types.zig");
const TextSystem = @import("text_system.zig").TextSystem;

const is_wasm = platform.is_wasm;
const ShapedRun = types.ShapedRun;
const ShapedGlyph = types.ShapedGlyph;
const Metrics = types.Metrics;

/// Platform name for debug output
pub const platform_name: []const u8 = if (is_wasm) "web" else "native";

/// Debug log function that works on both platforms
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (is_wasm) {
        const imports = @import("../platform/web/imports.zig");
        imports.log(fmt, args);
    } else {
        std.debug.print(fmt ++ "\n", args);
    }
}

/// Log details of a shaped text run
pub fn logShapedRun(text: []const u8, run: ShapedRun) void {
    debugLog("=== ShapedRun Debug ({s}) ===", .{platform_name});
    debugLog("  Text: \"{s}\"", .{text});
    debugLog("  Total width: {d:.3}", .{run.width});
    debugLog("  Glyph count: {d}", .{run.glyphs.len});

    var cumulative_advance: f32 = 0;
    for (run.glyphs, 0..) |glyph, i| {
        const char_preview = getCharPreview(text, glyph.cluster);
        debugLog("  [{d}] glyph_id={d} cluster={d} char='{s}'", .{ i, glyph.glyph_id, glyph.cluster, char_preview });
        debugLog("       x_advance={d:.3} x_offset={d:.3} y_offset={d:.3}", .{ glyph.x_advance, glyph.x_offset, glyph.y_offset });
        debugLog("       cumulative_x={d:.3}", .{cumulative_advance});
        cumulative_advance += glyph.x_advance + glyph.x_offset;
    }
    debugLog("  Final cumulative advance: {d:.3}", .{cumulative_advance});
    debugLog("===========================", .{});
}

/// Log font metrics
pub fn logFontMetrics(metrics: Metrics) void {
    debugLog("=== Font Metrics ({s}) ===", .{platform_name});
    debugLog("  point_size: {d:.2}", .{metrics.point_size});
    debugLog("  ascender: {d:.3}", .{metrics.ascender});
    debugLog("  descender: {d:.3}", .{metrics.descender});
    debugLog("  line_height: {d:.3}", .{metrics.line_height});
    debugLog("  line_gap: {d:.3}", .{metrics.line_gap});
    debugLog("  x_height: {d:.3}", .{metrics.x_height});
    debugLog("  cap_height: {d:.3}", .{metrics.cap_height});
    debugLog("  cell_width: {d:.3}", .{metrics.cell_width});
    debugLog("  is_monospace: {}", .{metrics.is_monospace});
    debugLog("==========================", .{});
}

/// Log detailed glyph rasterization info
pub fn logGlyphRasterization(
    glyph_id: u16,
    scale: f32,
    subpixel_x: u8,
    width: u32,
    height: u32,
    offset_x: i32,
    offset_y: i32,
    advance_x: f32,
) void {
    debugLog("=== Glyph Rasterization ({s}) ===", .{platform_name});
    debugLog("  glyph_id: {d}", .{glyph_id});
    debugLog("  scale: {d:.2}", .{scale});
    debugLog("  subpixel_x: {d}", .{subpixel_x});
    debugLog("  bitmap size: {d}x{d}", .{ width, height });
    debugLog("  offset: ({d}, {d})", .{ offset_x, offset_y });
    debugLog("  advance_x: {d:.3}", .{advance_x});
    debugLog("=================================", .{});
}

/// Shape text and log debug info
pub fn debugShapeText(text_system: *TextSystem, text: []const u8) !void {
    var shaped = try text_system.shapeText(text, null);
    defer shaped.deinit(text_system.allocator);

    logShapedRun(text, shaped);

    if (text_system.getMetrics()) |metrics| {
        logFontMetrics(metrics);
    }
}

/// Get character preview from cluster index
fn getCharPreview(text: []const u8, cluster: u32) []const u8 {
    if (cluster >= text.len) return "?";

    // Find the end of this UTF-8 character
    var end = cluster + 1;
    while (end < text.len and (text[end] & 0xC0) == 0x80) {
        end += 1;
    }

    return text[cluster..end];
}

/// Debug helper to compare glyph advances between platforms
/// Call this with the same text on both native and web builds
pub fn logGlyphAdvances(text_system: *TextSystem, text: []const u8) !void {
    var shaped = try text_system.shapeText(text, null);
    defer shaped.deinit(text_system.allocator);

    debugLog("Glyph advances for \"{s}\" ({s}):", .{ text, platform_name });

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    for (shaped.glyphs, 0..) |glyph, i| {
        const char_preview = getCharPreview(text, glyph.cluster);
        writer.print("{s}:{d:.2}", .{ char_preview, glyph.x_advance }) catch {};
        if (i < shaped.glyphs.len - 1) {
            writer.writeAll(" | ") catch {};
        }
    }

    debugLog("  {s}", .{stream.getWritten()});
    debugLog("  Total: {d:.3}", .{shaped.width});
}
