//! JSON Parser — Converts JSON lines into DrawCommands.
//!
//! Parses a single JSON object (one per line) into a `DrawCommand`, handling
//! the `"tool"` discriminator, numeric field extraction, hex color parsing,
//! semantic theme token resolution, and the `"text"` → `text_idx` asymmetry
//! for text commands.
//!
//! Input format (JSON-lines, one object per line):
//!
//!   {"tool":"fill_rect","x":10,"y":20,"w":100,"h":50,"color":"FF6B35"}
//!   {"tool":"fill_rect","x":10,"y":20,"w":100,"h":50,"color":"primary"}
//!   {"tool":"draw_text","text":"Hello","x":10,"y":20,"color":"text","font_size":16}
//!
//! Color fields accept either a hex string (e.g. "FF6B35", "#FF6B35") or a
//! semantic theme token (e.g. "primary", "surface", "text"). Theme tokens are
//! tried first via `SemanticToken.fromString`; on miss, hex parsing kicks in.
//!
//! Uses `std.json.parseFromSlice` (Zig 0.15 std lib) for parsing. The
//! allocator is temporary — the parsed tree is freed before returning.
//! The returned `DrawCommand` lives in the caller's pre-allocated buffer
//! (no allocation escapes this module).

const std = @import("std");
const Allocator = std.mem.Allocator;
const DrawCommand = @import("draw_command.zig").DrawCommand;
const TextPool = @import("text_pool.zig").TextPool;
const Color = @import("../core/geometry.zig").Color;
const ThemeColor = @import("theme_color.zig").ThemeColor;
const SemanticToken = @import("theme_color.zig").SemanticToken;

// =============================================================================
// Constants
// =============================================================================

/// Maximum byte length for a single JSON input line.
pub const MAX_JSON_LINE_SIZE: usize = 4096;

/// Number of known tool names (must match DrawCommand variant count).
const TOOL_COUNT: usize = 11;

// =============================================================================
// Public API
// =============================================================================

/// Parse a single JSON line into a `DrawCommand`.
///
/// For text commands (`draw_text`, `draw_text_centered`), the `"text"` string
/// is pushed into `texts` and the resulting index is stored as `text_idx` in
/// the command. This is the "schema aliasing" — external `"text": "string"`
/// maps to internal `text_idx: u16`.
///
/// Color fields accept hex strings ("FF6B35") or semantic theme tokens
/// ("primary", "surface", etc.). Tokens are tried first; hex is the fallback.
///
/// Returns `null` on any error: malformed JSON, unknown tool, missing fields,
/// oversized input. Fail-fast, no crash (CLAUDE.md rule #11).
pub fn parseCommand(
    allocator: Allocator,
    json_line: []const u8,
    texts: *TextPool,
) ?DrawCommand {
    // CLAUDE.md #3: assert input bounds at API boundary.
    std.debug.assert(json_line.len <= MAX_JSON_LINE_SIZE);

    if (json_line.len == 0) return null;
    if (json_line.len > MAX_JSON_LINE_SIZE) return null;

    // Parse JSON into a dynamic Value tree (temporary allocation).
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_line,
        .{},
    ) catch return null;
    defer parsed.deinit();

    const root = parsed.value;

    // Root must be an object.
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };

    // Extract the "tool" discriminator.
    const tool_name = getString(obj, "tool") orelse return null;

    // CLAUDE.md #3: assert tool name is non-empty.
    std.debug.assert(tool_name.len > 0);

    // Dispatch by tool name.
    return parseTool(tool_name, obj, texts);
}

// =============================================================================
// Tool Dispatch
// =============================================================================

/// Dispatch to the correct tool parser by name.
/// Returns null for unknown tool names (CLAUDE.md rule #11: negative space).
fn parseTool(
    tool_name: []const u8,
    obj: std.json.ObjectMap,
    texts: *TextPool,
) ?DrawCommand {
    // CLAUDE.md #3: assert non-empty tool name.
    std.debug.assert(tool_name.len > 0);

    // Fills
    if (std.mem.eql(u8, tool_name, "fill_rect")) return parseFillRect(obj);
    if (std.mem.eql(u8, tool_name, "fill_rounded_rect")) return parseFillRoundedRect(obj);
    if (std.mem.eql(u8, tool_name, "fill_circle")) return parseFillCircle(obj);
    if (std.mem.eql(u8, tool_name, "fill_ellipse")) return parseFillEllipse(obj);
    if (std.mem.eql(u8, tool_name, "fill_triangle")) return parseFillTriangle(obj);

    // Strokes / Lines
    if (std.mem.eql(u8, tool_name, "stroke_rect")) return parseStrokeRect(obj);
    if (std.mem.eql(u8, tool_name, "stroke_circle")) return parseStrokeCircle(obj);
    if (std.mem.eql(u8, tool_name, "line")) return parseLine(obj);

    // Text (requires TextPool mutation)
    if (std.mem.eql(u8, tool_name, "draw_text")) return parseDrawText(obj, texts);
    if (std.mem.eql(u8, tool_name, "draw_text_centered")) return parseDrawTextCentered(obj, texts);

    // Control
    if (std.mem.eql(u8, tool_name, "set_background")) return parseSetBackground(obj);

    // Unknown tool — negative space (CLAUDE.md #11).
    return null;
}

// =============================================================================
// Per-Tool Parsers
// =============================================================================

fn parseFillRect(obj: std.json.ObjectMap) ?DrawCommand {
    const x = getFloat(obj, "x") orelse return null;
    const y = getFloat(obj, "y") orelse return null;
    const w = getFloat(obj, "w") orelse return null;
    const h = getFloat(obj, "h") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .fill_rect = .{ .x = x, .y = y, .w = w, .h = h, .color = color } };
}

fn parseFillRoundedRect(obj: std.json.ObjectMap) ?DrawCommand {
    const x = getFloat(obj, "x") orelse return null;
    const y = getFloat(obj, "y") orelse return null;
    const w = getFloat(obj, "w") orelse return null;
    const h = getFloat(obj, "h") orelse return null;
    const radius = getFloat(obj, "radius") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .fill_rounded_rect = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .radius = radius,
        .color = color,
    } };
}

fn parseFillCircle(obj: std.json.ObjectMap) ?DrawCommand {
    const cx = getFloat(obj, "cx") orelse return null;
    const cy = getFloat(obj, "cy") orelse return null;
    const radius = getFloat(obj, "radius") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .fill_circle = .{ .cx = cx, .cy = cy, .radius = radius, .color = color } };
}

fn parseFillEllipse(obj: std.json.ObjectMap) ?DrawCommand {
    const cx = getFloat(obj, "cx") orelse return null;
    const cy = getFloat(obj, "cy") orelse return null;
    const rx = getFloat(obj, "rx") orelse return null;
    const ry = getFloat(obj, "ry") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .fill_ellipse = .{ .cx = cx, .cy = cy, .rx = rx, .ry = ry, .color = color } };
}

fn parseFillTriangle(obj: std.json.ObjectMap) ?DrawCommand {
    const x1 = getFloat(obj, "x1") orelse return null;
    const y1 = getFloat(obj, "y1") orelse return null;
    const x2 = getFloat(obj, "x2") orelse return null;
    const y2 = getFloat(obj, "y2") orelse return null;
    const x3 = getFloat(obj, "x3") orelse return null;
    const y3 = getFloat(obj, "y3") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .fill_triangle = .{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
        .x3 = x3,
        .y3 = y3,
        .color = color,
    } };
}

fn parseStrokeRect(obj: std.json.ObjectMap) ?DrawCommand {
    const x = getFloat(obj, "x") orelse return null;
    const y = getFloat(obj, "y") orelse return null;
    const w = getFloat(obj, "w") orelse return null;
    const h = getFloat(obj, "h") orelse return null;
    const width = getFloat(obj, "width") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .stroke_rect = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .width = width,
        .color = color,
    } };
}

fn parseStrokeCircle(obj: std.json.ObjectMap) ?DrawCommand {
    const cx = getFloat(obj, "cx") orelse return null;
    const cy = getFloat(obj, "cy") orelse return null;
    const radius = getFloat(obj, "radius") orelse return null;
    const width = getFloat(obj, "width") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .stroke_circle = .{
        .cx = cx,
        .cy = cy,
        .radius = radius,
        .width = width,
        .color = color,
    } };
}

fn parseLine(obj: std.json.ObjectMap) ?DrawCommand {
    const x1 = getFloat(obj, "x1") orelse return null;
    const y1 = getFloat(obj, "y1") orelse return null;
    const x2 = getFloat(obj, "x2") orelse return null;
    const y2 = getFloat(obj, "y2") orelse return null;
    const width = getFloat(obj, "width") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .line = .{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
        .width = width,
        .color = color,
    } };
}

/// Parse `draw_text`: extracts `"text"` string, pushes into TextPool,
/// stores resulting `text_idx` (schema aliasing: external `"text"` → internal `text_idx`).
fn parseDrawText(obj: std.json.ObjectMap, texts: *TextPool) ?DrawCommand {
    const text = getString(obj, "text") orelse return null;
    const x = getFloat(obj, "x") orelse return null;
    const y = getFloat(obj, "y") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    const font_size = getFloat(obj, "font_size") orelse return null;

    // Push text into pool — may return null if pool is full.
    const text_idx = texts.push(text) orelse return null;

    return .{ .draw_text = .{
        .text_idx = text_idx,
        .x = x,
        .y = y,
        .color = color,
        .font_size = font_size,
    } };
}

/// Parse `draw_text_centered`: same schema aliasing as `draw_text`.
fn parseDrawTextCentered(obj: std.json.ObjectMap, texts: *TextPool) ?DrawCommand {
    const text = getString(obj, "text") orelse return null;
    const x = getFloat(obj, "x") orelse return null;
    const y_center = getFloat(obj, "y_center") orelse return null;
    const color = getThemeColor(obj, "color") orelse return null;
    const font_size = getFloat(obj, "font_size") orelse return null;

    // Push text into pool — may return null if pool is full.
    const text_idx = texts.push(text) orelse return null;

    return .{ .draw_text_centered = .{
        .text_idx = text_idx,
        .x = x,
        .y_center = y_center,
        .color = color,
        .font_size = font_size,
    } };
}

fn parseSetBackground(obj: std.json.ObjectMap) ?DrawCommand {
    const color = getThemeColor(obj, "color") orelse return null;
    return .{ .set_background = .{ .color = color } };
}

// =============================================================================
// Field Extractors
// =============================================================================

/// Extract a numeric value from a JSON object field, coercing int → f32.
fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

/// Extract a string value from a JSON object field.
fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract a color from a JSON object field.
///
/// Tries semantic theme token first (e.g. "primary", "surface", "text"),
/// then falls back to hex color parsing (e.g. "FF6B35", "#FF6B35").
///
/// Accepts both `"FF6B35"` and `"#FF6B35"` formats (with or without `#`
/// prefix), as well as alpha variants like `"FF6B35CC"` / `"#RRGGBBAA"`.
///
/// Returns a `ThemeColor` — either `.token` for semantic references or
/// `.literal` for concrete hex colors.
fn getThemeColor(obj: std.json.ObjectMap, key: []const u8) ?ThemeColor {
    const color_str = getString(obj, key) orelse return null;

    // CLAUDE.md #3: assert color string is non-empty.
    std.debug.assert(color_str.len > 0);
    if (color_str.len == 0) return null;

    // Try semantic token first. Token names are pure lowercase alpha +
    // underscore (e.g. "primary", "border_focus"), so there's no ambiguity
    // with hex strings which are alphanumeric with optional '#' prefix.
    if (SemanticToken.fromString(color_str)) |token| {
        return ThemeColor.fromToken(token);
    }

    // Fall back to hex color parsing.
    // Valid formats: RGB(3), RGBA(4), RRGGBB(6), RRGGBBAA(8), plus optional '#'.
    if (color_str.len > 9) return null;
    return ThemeColor.fromLiteral(Color.fromHex(color_str));
}

// =============================================================================
// Compile-time Assertions (CLAUDE.md rules #3, #4)
// =============================================================================

comptime {
    // Guard: tool count must match DrawCommand variant count.
    // If someone adds a variant to DrawCommand, this reminds them to
    // update the parser dispatch table.
    std.debug.assert(TOOL_COUNT == std.meta.fields(DrawCommand).len);

    // Line size limit must be reasonable (not zero, not enormous).
    std.debug.assert(MAX_JSON_LINE_SIZE >= 64);
    std.debug.assert(MAX_JSON_LINE_SIZE <= 65536);
}

// =============================================================================
// Tests
// =============================================================================

test "parse fill_rect with hex color" {
    const input = "{\"tool\":\"fill_rect\",\"x\":10,\"y\":20,\"w\":100,\"h\":50,\"color\":\"FF6B35\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts) orelse
        return error.TestUnexpectedResult;

    switch (cmd) {
        .fill_rect => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 10), c.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20), c.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 100), c.w, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 50), c.h, 0.001);
            // Must be a literal color.
            try std.testing.expect(c.color.isLiteral());
            const lit = c.color.getLiteral().?;
            // FF = 255, 6B = 107, 35 = 53
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), lit.r, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 107.0 / 255.0), lit.g, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 53.0 / 255.0), lit.b, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), lit.a, 0.01);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse fill_rect with theme token" {
    const input = "{\"tool\":\"fill_rect\",\"x\":10,\"y\":20,\"w\":100,\"h\":50,\"color\":\"primary\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts) orelse
        return error.TestUnexpectedResult;

    switch (cmd) {
        .fill_rect => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 10), c.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 50), c.h, 0.001);
            // Must be a theme token.
            try std.testing.expect(c.color.isToken());
            try std.testing.expectEqual(SemanticToken.primary, c.color.getToken().?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse fill_rect with float values" {
    const input = "{\"tool\":\"fill_rect\",\"x\":10.5,\"y\":20.75,\"w\":100.0,\"h\":50.25,\"color\":\"FF0000\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .fill_rect => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 10.5), c.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20.75), c.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 100.0), c.w, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 50.25), c.h, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse fill_rounded_rect" {
    const input = "{\"tool\":\"fill_rounded_rect\",\"x\":0,\"y\":0,\"w\":200,\"h\":100,\"radius\":12,\"color\":\"00FF00\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .fill_rounded_rect => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 200), c.w, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 12), c.radius, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse fill_circle" {
    const input = "{\"tool\":\"fill_circle\",\"cx\":100,\"cy\":200,\"radius\":50,\"color\":\"0000FF\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .fill_circle => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 100), c.cx, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 200), c.cy, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 50), c.radius, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse fill_ellipse" {
    const input = "{\"tool\":\"fill_ellipse\",\"cx\":50,\"cy\":50,\"rx\":30,\"ry\":20,\"color\":\"ABCDEF\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .fill_ellipse => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 30), c.rx, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20), c.ry, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse fill_triangle" {
    const input = "{\"tool\":\"fill_triangle\",\"x1\":0,\"y1\":0,\"x2\":100,\"y2\":0,\"x3\":50,\"y3\":86,\"color\":\"CC3333\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .fill_triangle => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 50), c.x3, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 86), c.y3, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse stroke_rect" {
    const input = "{\"tool\":\"stroke_rect\",\"x\":5,\"y\":5,\"w\":90,\"h\":90,\"width\":2,\"color\":\"FFFFFF\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .stroke_rect => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 2), c.width, 0.001);
            try std.testing.expect(c.color.isLiteral());
            const lit = c.color.getLiteral().?;
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), lit.r, 0.01);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse stroke_circle" {
    const input = "{\"tool\":\"stroke_circle\",\"cx\":50,\"cy\":50,\"radius\":40,\"width\":3,\"color\":\"00FFFF\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .stroke_circle => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 40), c.radius, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 3), c.width, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse line" {
    const input = "{\"tool\":\"line\",\"x1\":0,\"y1\":0,\"x2\":100,\"y2\":100,\"width\":2,\"color\":\"FF00FF\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .line => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 100), c.x2, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 2), c.width, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse draw_text pushes to TextPool" {
    const input = "{\"tool\":\"draw_text\",\"text\":\"Hello AI\",\"x\":10,\"y\":20,\"color\":\"FFFFFF\",\"font_size\":16}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .draw_text => |c| {
            try std.testing.expectEqual(@as(u16, 0), c.text_idx);
            try std.testing.expectApproxEqAbs(@as(f32, 10), c.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 16), c.font_size, 0.001);
            // Verify the text was pushed into the pool.
            try std.testing.expectEqualStrings("Hello AI", texts.get(c.text_idx));
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u16, 1), texts.entryCount());
}

test "parse draw_text with theme token color" {
    const input = "{\"tool\":\"draw_text\",\"text\":\"Themed\",\"x\":10,\"y\":20,\"color\":\"text\",\"font_size\":16}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .draw_text => |c| {
            try std.testing.expect(c.color.isToken());
            try std.testing.expectEqual(SemanticToken.text, c.color.getToken().?);
            try std.testing.expectEqualStrings("Themed", texts.get(c.text_idx));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse draw_text_centered pushes to TextPool" {
    const input = "{\"tool\":\"draw_text_centered\",\"text\":\"Centered\",\"x\":100,\"y_center\":300,\"color\":\"000000\",\"font_size\":24}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .draw_text_centered => |c| {
            try std.testing.expectEqual(@as(u16, 0), c.text_idx);
            try std.testing.expectApproxEqAbs(@as(f32, 300), c.y_center, 0.001);
            try std.testing.expectEqualStrings("Centered", texts.get(c.text_idx));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse set_background with hex" {
    const input = "{\"tool\":\"set_background\",\"color\":\"87CEEB\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .set_background => |c| {
            try std.testing.expect(c.color.isLiteral());
            const lit = c.color.getLiteral().?;
            // 87 = 135, CE = 206, EB = 235
            try std.testing.expectApproxEqAbs(@as(f32, 135.0 / 255.0), lit.r, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 206.0 / 255.0), lit.g, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 235.0 / 255.0), lit.b, 0.01);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse set_background with theme token" {
    const input = "{\"tool\":\"set_background\",\"color\":\"bg\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .set_background => |c| {
            try std.testing.expect(c.color.isToken());
            try std.testing.expectEqual(SemanticToken.bg, c.color.getToken().?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "color parsing with hash prefix" {
    const input = "{\"tool\":\"fill_circle\",\"cx\":0,\"cy\":0,\"radius\":1,\"color\":\"#FF6B35\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .fill_circle => |c| {
            try std.testing.expect(c.color.isLiteral());
            const lit = c.color.getLiteral().?;
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), lit.r, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 107.0 / 255.0), lit.g, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 53.0 / 255.0), lit.b, 0.01);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "color parsing with alpha" {
    const input = "{\"tool\":\"set_background\",\"color\":\"FF6B35CC\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .set_background => |c| {
            try std.testing.expect(c.color.isLiteral());
            const lit = c.color.getLiteral().?;
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), lit.r, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 107.0 / 255.0), lit.g, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 53.0 / 255.0), lit.b, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 204.0 / 255.0), lit.a, 0.01);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "color parsing with hash and alpha" {
    const input = "{\"tool\":\"set_background\",\"color\":\"#FF6B35CC\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .set_background => |c| {
            try std.testing.expect(c.color.isLiteral());
            const lit = c.color.getLiteral().?;
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), lit.r, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 204.0 / 255.0), lit.a, 0.01);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "all 14 semantic tokens parse correctly" {
    const token_names = [_][]const u8{
        "bg",      "surface",      "overlay",
        "primary", "secondary",    "accent",
        "success", "warning",      "danger",
        "text",    "subtext",      "muted",
        "border",  "border_focus",
    };

    // CLAUDE.md #3: assert we're testing all tokens.
    std.debug.assert(token_names.len == SemanticToken.COUNT);

    for (token_names) |token_name| {
        // Build a set_background command with this token.
        var buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"tool\":\"set_background\",\"color\":\"{s}\"}}", .{token_name}) catch unreachable;

        var texts = TextPool{};
        const cmd = parseCommand(std.testing.allocator, json, &texts) orelse
            return error.TestUnexpectedResult;

        switch (cmd) {
            .set_background => |c| {
                try std.testing.expect(c.color.isToken());
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "malformed JSON returns null" {
    var texts = TextPool{};
    try std.testing.expect(parseCommand(std.testing.allocator, "{not json", &texts) == null);
    try std.testing.expect(parseCommand(std.testing.allocator, "", &texts) == null);
    try std.testing.expect(parseCommand(std.testing.allocator, "[]", &texts) == null);
    try std.testing.expect(parseCommand(std.testing.allocator, "42", &texts) == null);
    try std.testing.expect(parseCommand(std.testing.allocator, "\"string\"", &texts) == null);
    try std.testing.expect(parseCommand(std.testing.allocator, "null", &texts) == null);
}

test "unknown tool returns null" {
    const input = "{\"tool\":\"unknown_tool\",\"x\":10}";
    var texts = TextPool{};
    try std.testing.expect(parseCommand(std.testing.allocator, input, &texts) == null);
}

test "missing tool field returns null" {
    const input = "{\"x\":10,\"y\":20}";
    var texts = TextPool{};
    try std.testing.expect(parseCommand(std.testing.allocator, input, &texts) == null);
}

test "missing required field returns null" {
    // fill_rect needs x, y, w, h, color — missing "h"
    const input = "{\"tool\":\"fill_rect\",\"x\":10,\"y\":20,\"w\":100,\"color\":\"FF0000\"}";
    var texts = TextPool{};
    try std.testing.expect(parseCommand(std.testing.allocator, input, &texts) == null);
}

test "wrong field type returns null" {
    // "x" should be a number, not a string
    const input = "{\"tool\":\"fill_rect\",\"x\":\"ten\",\"y\":20,\"w\":100,\"h\":50,\"color\":\"FF0000\"}";
    var texts = TextPool{};
    try std.testing.expect(parseCommand(std.testing.allocator, input, &texts) == null);
}

test "multiple text commands get sequential indices" {
    var texts = TextPool{};

    const input1 = "{\"tool\":\"draw_text\",\"text\":\"First\",\"x\":0,\"y\":0,\"color\":\"FFF\",\"font_size\":12}";
    const cmd1 = parseCommand(std.testing.allocator, input1, &texts).?;

    const input2 = "{\"tool\":\"draw_text\",\"text\":\"Second\",\"x\":0,\"y\":20,\"color\":\"FFF\",\"font_size\":12}";
    const cmd2 = parseCommand(std.testing.allocator, input2, &texts).?;

    switch (cmd1) {
        .draw_text => |c| {
            try std.testing.expectEqual(@as(u16, 0), c.text_idx);
            try std.testing.expectEqualStrings("First", texts.get(c.text_idx));
        },
        else => return error.TestUnexpectedResult,
    }

    switch (cmd2) {
        .draw_text => |c| {
            try std.testing.expectEqual(@as(u16, 1), c.text_idx);
            try std.testing.expectEqualStrings("Second", texts.get(c.text_idx));
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(u16, 2), texts.entryCount());
}

test "draw_text missing text field returns null" {
    const input = "{\"tool\":\"draw_text\",\"x\":10,\"y\":20,\"color\":\"FFFFFF\",\"font_size\":16}";
    var texts = TextPool{};
    try std.testing.expect(parseCommand(std.testing.allocator, input, &texts) == null);
    // No text should have been pushed.
    try std.testing.expectEqual(@as(u16, 0), texts.entryCount());
}

test "parse all 11 tool types successfully" {
    var texts = TextPool{};
    const inputs = [_][]const u8{
        "{\"tool\":\"fill_rect\",\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"color\":\"FFF\"}",
        "{\"tool\":\"fill_rounded_rect\",\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"radius\":4,\"color\":\"FFF\"}",
        "{\"tool\":\"fill_circle\",\"cx\":0,\"cy\":0,\"radius\":1,\"color\":\"FFF\"}",
        "{\"tool\":\"fill_ellipse\",\"cx\":0,\"cy\":0,\"rx\":1,\"ry\":2,\"color\":\"FFF\"}",
        "{\"tool\":\"fill_triangle\",\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":0,\"x3\":0,\"y3\":1,\"color\":\"FFF\"}",
        "{\"tool\":\"stroke_rect\",\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"width\":2,\"color\":\"FFF\"}",
        "{\"tool\":\"stroke_circle\",\"cx\":0,\"cy\":0,\"radius\":1,\"width\":2,\"color\":\"FFF\"}",
        "{\"tool\":\"line\",\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"width\":1,\"color\":\"FFF\"}",
        "{\"tool\":\"draw_text\",\"text\":\"a\",\"x\":0,\"y\":0,\"color\":\"FFF\",\"font_size\":12}",
        "{\"tool\":\"draw_text_centered\",\"text\":\"b\",\"x\":0,\"y_center\":0,\"color\":\"FFF\",\"font_size\":12}",
        "{\"tool\":\"set_background\",\"color\":\"FFF\"}",
    };

    var parsed_count: usize = 0;
    for (inputs) |input| {
        if (parseCommand(std.testing.allocator, input, &texts) != null) {
            parsed_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 11), parsed_count);
}

test "parse all 11 tool types with theme tokens" {
    var texts = TextPool{};
    const inputs = [_][]const u8{
        "{\"tool\":\"fill_rect\",\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"color\":\"primary\"}",
        "{\"tool\":\"fill_rounded_rect\",\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"radius\":4,\"color\":\"surface\"}",
        "{\"tool\":\"fill_circle\",\"cx\":0,\"cy\":0,\"radius\":1,\"color\":\"accent\"}",
        "{\"tool\":\"fill_ellipse\",\"cx\":0,\"cy\":0,\"rx\":1,\"ry\":2,\"color\":\"success\"}",
        "{\"tool\":\"fill_triangle\",\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":0,\"x3\":0,\"y3\":1,\"color\":\"warning\"}",
        "{\"tool\":\"stroke_rect\",\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"width\":2,\"color\":\"danger\"}",
        "{\"tool\":\"stroke_circle\",\"cx\":0,\"cy\":0,\"radius\":1,\"width\":2,\"color\":\"border\"}",
        "{\"tool\":\"line\",\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"width\":1,\"color\":\"muted\"}",
        "{\"tool\":\"draw_text\",\"text\":\"a\",\"x\":0,\"y\":0,\"color\":\"text\",\"font_size\":12}",
        "{\"tool\":\"draw_text_centered\",\"text\":\"b\",\"x\":0,\"y_center\":0,\"color\":\"subtext\",\"font_size\":12}",
        "{\"tool\":\"set_background\",\"color\":\"bg\"}",
    };

    var parsed_count: usize = 0;
    for (inputs) |input| {
        const cmd = parseCommand(std.testing.allocator, input, &texts) orelse continue;
        // Every parsed command should have a theme token color.
        try std.testing.expect(cmd.getColor().isToken());
        parsed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 11), parsed_count);
}

test "house example from design doc" {
    // Reproduces the Python "draw a house" example from AI_NATIVE.md
    var texts = TextPool{};
    const commands_json = [_][]const u8{
        "{\"tool\":\"set_background\",\"color\":\"87CEEB\"}",
        "{\"tool\":\"fill_rect\",\"x\":200,\"y\":250,\"w\":200,\"h\":150,\"color\":\"8B4513\"}",
        "{\"tool\":\"fill_triangle\",\"x1\":180,\"y1\":250,\"x2\":300,\"y2\":120,\"x3\":420,\"y3\":250,\"color\":\"CC3333\"}",
        "{\"tool\":\"fill_rect\",\"x\":270,\"y\":320,\"w\":60,\"h\":80,\"color\":\"654321\"}",
        "{\"tool\":\"fill_circle\",\"cx\":250,\"cy\":300,\"radius\":20,\"color\":\"#4A90D9\"}",
        "{\"tool\":\"draw_text\",\"text\":\"Home\",\"x\":260,\"y\":410,\"color\":\"FFFFFF\",\"font_size\":20}",
    };

    var parsed: [commands_json.len]DrawCommand = undefined;
    for (commands_json, 0..) |json_line, i| {
        parsed[i] = parseCommand(std.testing.allocator, json_line, &texts) orelse
            return error.TestUnexpectedResult;
    }

    // Verify specific commands.
    switch (parsed[0]) {
        .set_background => {},
        else => return error.TestUnexpectedResult,
    }
    switch (parsed[1]) {
        .fill_rect => |c| try std.testing.expectApproxEqAbs(@as(f32, 200), c.x, 0.001),
        else => return error.TestUnexpectedResult,
    }
    switch (parsed[2]) {
        .fill_triangle => {},
        else => return error.TestUnexpectedResult,
    }
    switch (parsed[5]) {
        .draw_text => |c| try std.testing.expectEqualStrings("Home", texts.get(c.text_idx)),
        else => return error.TestUnexpectedResult,
    }
}

test "themed house example" {
    // Same house but using theme tokens for coherent styling.
    var texts = TextPool{};
    const commands_json = [_][]const u8{
        "{\"tool\":\"set_background\",\"color\":\"bg\"}",
        "{\"tool\":\"fill_rect\",\"x\":200,\"y\":250,\"w\":200,\"h\":150,\"color\":\"surface\"}",
        "{\"tool\":\"fill_triangle\",\"x1\":180,\"y1\":250,\"x2\":300,\"y2\":120,\"x3\":420,\"y3\":250,\"color\":\"danger\"}",
        "{\"tool\":\"fill_rect\",\"x\":270,\"y\":320,\"w\":60,\"h\":80,\"color\":\"secondary\"}",
        "{\"tool\":\"fill_circle\",\"cx\":250,\"cy\":300,\"radius\":20,\"color\":\"primary\"}",
        "{\"tool\":\"draw_text\",\"text\":\"Home\",\"x\":260,\"y\":410,\"color\":\"text\",\"font_size\":20}",
    };

    for (commands_json) |json_line| {
        const cmd = parseCommand(std.testing.allocator, json_line, &texts) orelse
            return error.TestUnexpectedResult;
        // All commands should have theme token colors.
        try std.testing.expect(cmd.getColor().isToken());
    }
}

test "extra fields are ignored gracefully" {
    // AI models may send extra fields — they should not cause a parse failure.
    const input = "{\"tool\":\"fill_rect\",\"x\":10,\"y\":20,\"w\":100,\"h\":50,\"color\":\"FF0000\",\"label\":\"my rect\",\"id\":42}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts);
    try std.testing.expect(cmd != null);
    switch (cmd.?) {
        .fill_rect => |c| try std.testing.expectApproxEqAbs(@as(f32, 10), c.x, 0.001),
        else => return error.TestUnexpectedResult,
    }
}

test "negative coordinate values" {
    const input = "{\"tool\":\"line\",\"x1\":-10,\"y1\":-20,\"x2\":100,\"y2\":200,\"width\":1,\"color\":\"FFF\"}";
    var texts = TextPool{};
    const cmd = parseCommand(std.testing.allocator, input, &texts).?;

    switch (cmd) {
        .line => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, -10), c.x1, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, -20), c.y1, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool count matches DrawCommand variant count" {
    try std.testing.expectEqual(@as(usize, 11), TOOL_COUNT);
    try std.testing.expectEqual(TOOL_COUNT, std.meta.fields(DrawCommand).len);
}

test "mixed hex and token colors in batch" {
    var texts = TextPool{};

    // Background with theme token.
    const cmd1 = parseCommand(
        std.testing.allocator,
        "{\"tool\":\"set_background\",\"color\":\"bg\"}",
        &texts,
    ).?;
    try std.testing.expect(cmd1.getColor().isToken());

    // Rect with hex color.
    const cmd2 = parseCommand(
        std.testing.allocator,
        "{\"tool\":\"fill_rect\",\"x\":0,\"y\":0,\"w\":100,\"h\":50,\"color\":\"FF6B35\"}",
        &texts,
    ).?;
    try std.testing.expect(cmd2.getColor().isLiteral());

    // Circle with theme token.
    const cmd3 = parseCommand(
        std.testing.allocator,
        "{\"tool\":\"fill_circle\",\"cx\":50,\"cy\":50,\"radius\":20,\"color\":\"accent\"}",
        &texts,
    ).?;
    try std.testing.expect(cmd3.getColor().isToken());
    try std.testing.expectEqual(SemanticToken.accent, cmd3.getColor().getToken().?);
}
