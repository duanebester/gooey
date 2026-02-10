//! Schema Generation — Comptime tool schema derived from DrawCommand type.
//!
//! Generates a JSON tool schema string at comptime by reflecting over the
//! `DrawCommand` tagged union. Each variant becomes a tool, each payload
//! struct field becomes a parameter. The schema and the command type are
//! the same source of truth — they cannot drift.
//!
//! **Schema aliasing:** The internal field `text_idx: u16` (a pool index)
//! is emitted as `"text": { "type": "string" }` in the external schema.
//! The JSON parser handles the reverse mapping. This is the one place
//! where internal representation and external schema intentionally diverge.
//!
//! **Theme colors:** Color fields use `ThemeColor` internally (a tagged
//! union of `Color | SemanticToken`). In the external schema they remain
//! `"type": "string"` — the description lists all valid semantic token
//! names alongside the hex format, derived at comptime from the
//! `SemanticToken` enum so they cannot drift from the Theme struct.
//!
//! Zero runtime cost, zero allocation — the schema is a comptime string literal
//! baked into the binary.

const std = @import("std");
const DrawCommand = @import("draw_command.zig").DrawCommand;
const Color = @import("../core/geometry.zig").Color;
const ThemeColor = @import("theme_color.zig").ThemeColor;
const SemanticToken = @import("theme_color.zig").SemanticToken;
const semantic_token_list = @import("theme_color.zig").semantic_token_list;

// =============================================================================
// Public API
// =============================================================================

/// The complete JSON tool schema array, generated at comptime from DrawCommand.
/// This is a `[]const u8` string literal — zero runtime cost.
pub const tool_schema: []const u8 = generateToolSchema(DrawCommand);

/// Number of tools in the generated schema (must match DrawCommand variant count).
pub const TOOL_COUNT: usize = std.meta.fields(DrawCommand).len;

// =============================================================================
// Comptime Schema Generator
// =============================================================================

/// Generate a JSON tool schema array from a DrawCommand-shaped tagged union.
/// Iterates union variants at comptime; each becomes a tool with parameters
/// derived from the variant's payload struct fields.
fn generateToolSchema(comptime Command: type) []const u8 {
    @setEvalBranchQuota(100_000);
    comptime {
        const fields = std.meta.fields(Command);

        // Assert expected variant count — update if DrawCommand evolves.
        std.debug.assert(fields.len == 11);

        var schema: []const u8 = "[\n";
        for (fields, 0..) |variant, i| {
            schema = schema ++ emitToolObject(variant.name, variant.type);
            if (i < fields.len - 1) {
                schema = schema ++ ",";
            }
            schema = schema ++ "\n";
        }
        schema = schema ++ "]";

        // Assert tool count in output matches variant count.
        std.debug.assert(comptimeCountSubstring(schema, "\"name\":") == fields.len);

        return schema;
    }
}

/// Emit a single tool JSON object for one DrawCommand variant.
/// `name` is the variant name (e.g. "fill_rect"), `Payload` is its struct type.
fn emitToolObject(comptime name: []const u8, comptime Payload: type) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);
        std.debug.assert(@typeInfo(Payload) == .@"struct");

        var out: []const u8 = "";
        out = out ++ "  {\n";
        out = out ++ "    \"name\": \"" ++ name ++ "\",\n";
        out = out ++ "    \"description\": \"" ++ toolDescription(name) ++ "\",\n";
        out = out ++ "    \"parameters\": {\n";
        out = out ++ emitParameters(Payload);
        out = out ++ "    }\n";
        out = out ++ "  }";
        return out;
    }
}

fn emitParameters(comptime Payload: type) []const u8 {
    comptime {
        const param_fields = std.meta.fields(Payload);
        std.debug.assert(param_fields.len >= 1); // Every tool has at least one param.

        var out: []const u8 = "";
        for (param_fields, 0..) |field, j| {
            const ext_name = fieldExternalName(field.name);
            const json_type = fieldJsonType(field.name, field.type);
            const desc = fieldDescription(field.name);

            out = out ++ "      \"" ++ ext_name ++ "\": { ";
            out = out ++ "\"type\": \"" ++ json_type ++ "\", ";
            out = out ++ "\"description\": \"" ++ desc ++ "\" }";
            if (j < param_fields.len - 1) {
                out = out ++ ",";
            }
            out = out ++ "\n";
        }
        return out;
    }
}

// =============================================================================
// Comptime Lookups — Descriptions
// =============================================================================

/// Map variant name to a human-readable tool description.
fn toolDescription(comptime name: []const u8) []const u8 {
    const descriptions = .{
        .{ "fill_rect", "Fill a rectangle with a solid color" },
        .{ "fill_rounded_rect", "Fill a rounded rectangle with a solid color" },
        .{ "fill_circle", "Fill a circle with a solid color" },
        .{ "fill_ellipse", "Fill an ellipse with a solid color" },
        .{ "fill_triangle", "Fill a triangle defined by three vertices" },
        .{ "stroke_rect", "Stroke a rectangle outline" },
        .{ "stroke_circle", "Stroke a circle outline" },
        .{ "line", "Draw a line between two points" },
        .{ "draw_text", "Render text at a position on the canvas" },
        .{ "draw_text_centered", "Render text vertically centered at a Y position" },
        .{ "set_background", "Fill the entire canvas with a background color. Use as the first command in a batch to clear the slate" },
    };
    inline for (descriptions) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    @compileError("unknown tool variant: " ++ name);
}

/// Map internal field name to external JSON schema name.
/// Handles the text_idx → text alias; all others pass through.
fn fieldExternalName(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "text_idx")) return "text";
    std.debug.assert(name.len > 0);
    return name;
}

/// Map a field to its JSON schema type string.
/// - `f32` → `"number"`
/// - `ThemeColor` → `"string"` (hex color or semantic theme token)
/// - `text_idx: u16` → `"string"` (schema aliasing: pool index → text)
/// - `u16` (non-aliased) → `"number"`
fn fieldJsonType(comptime name: []const u8, comptime T: type) []const u8 {
    // Schema aliasing: text_idx is a u16 internally but string externally.
    if (std.mem.eql(u8, name, "text_idx")) {
        std.debug.assert(T == u16);
        return "string";
    }
    if (T == f32) return "number";
    if (T == ThemeColor) return "string";
    if (T == u16) return "number";
    @compileError("unsupported field type for schema generation");
}

/// Map field name to a human-readable parameter description.
///
/// The `"color"` description is generated at comptime from the `SemanticToken`
/// enum — if a new token is added to Theme/SemanticToken, the schema
/// description updates automatically. Single source of truth, zero drift.
fn fieldDescription(comptime name: []const u8) []const u8 {
    // Color description: derived from SemanticToken enum at comptime.
    if (std.mem.eql(u8, name, "color")) {
        return "Hex color (e.g. 'FF6B35') or theme token: " ++ semantic_token_list;
    }

    const descriptions = .{
        .{ "x", "X position (pixels from left)" },
        .{ "y", "Y position (pixels from top)" },
        .{ "w", "Width in pixels" },
        .{ "h", "Height in pixels" },
        .{ "cx", "Center X" },
        .{ "cy", "Center Y" },
        .{ "rx", "Horizontal radius in pixels" },
        .{ "ry", "Vertical radius in pixels" },
        .{ "radius", "Radius in pixels" },
        .{ "width", "Stroke width in pixels" },
        .{ "text_idx", "The text content to render" },
        .{ "font_size", "Font size in pixels" },
        .{ "x1", "First point X" },
        .{ "y1", "First point Y" },
        .{ "x2", "Second point X" },
        .{ "y2", "Second point Y" },
        .{ "x3", "Third point X" },
        .{ "y3", "Third point Y" },
        .{ "y_center", "Y position to vertically center text on" },
    };
    inline for (descriptions) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    @compileError("unknown field for description: " ++ name);
}

// =============================================================================
// Comptime Utilities
// =============================================================================

/// Count non-overlapping occurrences of `needle` in `haystack` at comptime.
fn comptimeCountSubstring(comptime haystack: []const u8, comptime needle: []const u8) usize {
    @setEvalBranchQuota(100_000);
    comptime {
        std.debug.assert(needle.len > 0);
        std.debug.assert(haystack.len >= needle.len);

        var count: usize = 0;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                count += 1;
                i += needle.len - 1; // Skip past match (non-overlapping).
            }
        }
        return count;
    }
}

// =============================================================================
// Compile-time Assertions (CLAUDE.md rules #3, #4)
// =============================================================================

comptime {
    @setEvalBranchQuota(100_000);
    // Schema must be non-empty.
    std.debug.assert(tool_schema.len > 0);

    // Schema starts with array bracket.
    std.debug.assert(tool_schema[0] == '[');

    // Schema ends with array bracket.
    std.debug.assert(tool_schema[tool_schema.len - 1] == ']');

    // Tool count in schema matches DrawCommand variant count.
    std.debug.assert(comptimeCountSubstring(tool_schema, "\"name\":") == TOOL_COUNT);

    // Every tool has a parameters block.
    std.debug.assert(comptimeCountSubstring(tool_schema, "\"parameters\":") == TOOL_COUNT);

    // Every tool has a description.
    std.debug.assert(comptimeCountSubstring(tool_schema, "\"description\":") > TOOL_COUNT);

    // Verify the text aliasing worked: "text" appears as a param name,
    // "text_idx" does NOT appear anywhere in the schema.
    std.debug.assert(comptimeCountSubstring(tool_schema, "\"text\":") >= 2); // draw_text + draw_text_centered
    std.debug.assert(comptimeCountSubstring(tool_schema, "text_idx") == 0);

    // Verify semantic token names appear in the schema (via color descriptions).
    // "primary" must appear at least once (it's in every color description).
    std.debug.assert(comptimeCountSubstring(tool_schema, "primary") >= 1);
    // "theme token" must appear in color descriptions.
    std.debug.assert(comptimeCountSubstring(tool_schema, "theme token") >= 1);
}

// =============================================================================
// Tests
// =============================================================================

test "tool_schema is non-empty comptime string" {
    try std.testing.expect(tool_schema.len > 0);
    try std.testing.expectEqual(@as(u8, '['), tool_schema[0]);
    try std.testing.expectEqual(@as(u8, ']'), tool_schema[tool_schema.len - 1]);
}

test "tool_schema contains exactly 11 tools" {
    var count: usize = 0;
    var offset: usize = 0;
    const needle = "\"name\":";
    while (offset + needle.len <= tool_schema.len) : (offset += 1) {
        if (std.mem.eql(u8, tool_schema[offset..][0..needle.len], needle)) {
            count += 1;
            offset += needle.len - 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 11), count);
}

test "tool_schema roundtrip parses as valid JSON" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    // Root is an array.
    try std.testing.expect(parsed.value == .array);

    // Contains exactly 11 tools.
    const tools = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 11), tools.items.len);

    // Each tool has name, description, parameters.
    for (tools.items) |tool| {
        try std.testing.expect(tool == .object);
        const obj = tool.object;
        try std.testing.expect(obj.contains("name"));
        try std.testing.expect(obj.contains("description"));
        try std.testing.expect(obj.contains("parameters"));

        // Parameters is an object with at least one entry.
        const params = obj.get("parameters").?;
        try std.testing.expect(params == .object);
        try std.testing.expect(params.object.count() >= 1);
    }
}

test "tool_schema contains all expected tool names" {
    const expected_names = [_][]const u8{
        "fill_rect",
        "fill_rounded_rect",
        "fill_circle",
        "fill_ellipse",
        "fill_triangle",
        "stroke_rect",
        "stroke_circle",
        "line",
        "draw_text",
        "draw_text_centered",
        "set_background",
    };
    for (expected_names) |name| {
        try std.testing.expect(std.mem.indexOf(u8, tool_schema, name) != null);
    }
}

test "text_idx aliased to text in schema" {
    // "text_idx" must not appear in the public schema.
    try std.testing.expect(std.mem.indexOf(u8, tool_schema, "text_idx") == null);

    // "text" must appear as a parameter (for draw_text and draw_text_centered).
    // Parse and check the actual tools.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    var text_param_count: usize = 0;
    for (parsed.value.array.items) |tool| {
        const params = tool.object.get("parameters").?.object;
        if (params.contains("text")) {
            // The "text" param must be type "string".
            const text_param = params.get("text").?.object;
            const type_val = text_param.get("type").?;
            try std.testing.expect(type_val == .string);
            try std.testing.expectEqualStrings("string", type_val.string);
            text_param_count += 1;
        }
    }
    // Exactly draw_text and draw_text_centered have a "text" parameter.
    try std.testing.expectEqual(@as(usize, 2), text_param_count);
}

test "color fields are typed as string in schema" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    // Every tool has a "color" parameter typed as "string".
    for (parsed.value.array.items) |tool| {
        const params = tool.object.get("parameters").?.object;
        const color_param = params.get("color") orelse continue;
        const type_val = color_param.object.get("type").?;
        try std.testing.expect(type_val == .string);
        try std.testing.expectEqualStrings("string", type_val.string);
    }
}

test "color description contains theme token names" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    // Check that color descriptions mention semantic tokens.
    for (parsed.value.array.items) |tool| {
        const params = tool.object.get("parameters").?.object;
        const color_param = params.get("color") orelse continue;
        const desc = color_param.object.get("description").?.string;

        // Must mention hex format.
        try std.testing.expect(std.mem.indexOf(u8, desc, "FF6B35") != null);

        // Must mention theme tokens.
        try std.testing.expect(std.mem.indexOf(u8, desc, "theme token") != null);

        // Must list specific token names from SemanticToken enum.
        try std.testing.expect(std.mem.indexOf(u8, desc, "primary") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "surface") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "bg") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "text") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "danger") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "border_focus") != null);
    }
}

test "numeric fields are typed as number in schema" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    // Check fill_rect: x, y, w, h should all be "number".
    const fill_rect_tool = parsed.value.array.items[0];
    try std.testing.expectEqualStrings("fill_rect", fill_rect_tool.object.get("name").?.string);

    const params = fill_rect_tool.object.get("parameters").?.object;
    const number_fields = [_][]const u8{ "x", "y", "w", "h" };
    for (number_fields) |field_name| {
        const field_obj = params.get(field_name).?.object;
        try std.testing.expectEqualStrings("number", field_obj.get("type").?.string);
    }
}

test "tool count matches DrawCommand variant count" {
    const variant_count = std.meta.fields(DrawCommand).len;
    try std.testing.expectEqual(variant_count, TOOL_COUNT);
    try std.testing.expectEqual(@as(usize, 11), TOOL_COUNT);
}

test "set_background has exactly one parameter" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    // set_background is the last tool.
    const last_tool = parsed.value.array.items[10];
    try std.testing.expectEqualStrings("set_background", last_tool.object.get("name").?.string);

    const params = last_tool.object.get("parameters").?.object;
    try std.testing.expectEqual(@as(usize, 1), params.count());
    try std.testing.expect(params.contains("color"));
}

test "fill_triangle has seven parameters" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    // fill_triangle is index 4.
    const triangle_tool = parsed.value.array.items[4];
    try std.testing.expectEqualStrings("fill_triangle", triangle_tool.object.get("name").?.string);

    const params = triangle_tool.object.get("parameters").?.object;
    try std.testing.expectEqual(@as(usize, 7), params.count());
}

test "all parameter fields have type and description" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tool_schema,
        .{},
    );
    defer parsed.deinit();

    for (parsed.value.array.items) |tool| {
        const tool_name = tool.object.get("name").?.string;
        const params = tool.object.get("parameters").?.object;
        var it = params.iterator();
        var param_count: usize = 0;
        while (it.next()) |entry| {
            _ = tool_name;
            const param_obj = entry.value_ptr.object;
            // Every parameter must have "type" and "description".
            try std.testing.expect(param_obj.contains("type"));
            try std.testing.expect(param_obj.contains("description"));
            // Type must be "number" or "string".
            const type_str = param_obj.get("type").?.string;
            const is_valid = std.mem.eql(u8, type_str, "number") or
                std.mem.eql(u8, type_str, "string");
            try std.testing.expect(is_valid);
            // Description must be non-empty.
            try std.testing.expect(param_obj.get("description").?.string.len > 0);
            param_count += 1;
        }
        // Every tool must have at least one parameter.
        try std.testing.expect(param_count >= 1);
    }
}
