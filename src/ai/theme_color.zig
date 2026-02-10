//! ThemeColor — Semantic color reference for AI draw commands.
//!
//! A color that is either a literal RGBA value or a reference to a semantic
//! theme token (e.g. "primary", "surface", "text"). Theme tokens resolve
//! against the active `Theme` at replay time, so AI-generated drawings
//! automatically adapt to light/dark mode and custom themes.
//!
//! ## Size Budget
//!
//! `ThemeColor` replaces `Color` (16 bytes) in `DrawCommand` variants.
//! The tagged union is ≤20 bytes — only 4 bytes larger than a raw `Color`.
//! `DrawCommand` stays well under the 64-byte cache line cap.
//!
//! ## Parsing
//!
//! The JSON parser calls `SemanticToken.fromString` first. If the color
//! string matches a token name (e.g. `"primary"`), it stores a `.token`
//! variant. Otherwise it falls through to hex parsing and stores `.literal`.
//! This means `"color": "primary"` and `"color": "FF6B35"` both work in
//! the same field — no schema changes needed beyond the description.

const std = @import("std");
const Color = @import("../core/geometry.zig").Color;
const Theme = @import("../ui/theme.zig").Theme;

// =============================================================================
// SemanticToken
// =============================================================================

/// Enum of semantic color slots that mirror `Theme` struct fields 1:1.
/// The variant names are identical to the Theme field names so that
/// `@tagName` produces the exact string the LLM sends in JSON.
pub const SemanticToken = enum(u8) {
    // Backgrounds
    bg,
    surface,
    overlay,

    // Accents
    primary,
    secondary,
    accent,
    success,
    warning,
    danger,

    // Text
    text,
    subtext,
    muted,

    // Borders
    border,
    border_focus,

    /// Number of semantic tokens. Must match Theme color field count.
    pub const COUNT: usize = @typeInfo(SemanticToken).@"enum".fields.len;

    /// Try to parse a string as a semantic token name.
    /// Returns null for strings that don't match any token (e.g. hex colors).
    /// Uses `std.meta.stringToEnum` — O(n) scan over 14 variants, fine at
    /// parse time (not per-frame).
    pub fn fromString(str: []const u8) ?SemanticToken {
        // CLAUDE.md #3: assert input is non-empty.
        std.debug.assert(str.len > 0);

        // Quick reject: hex colors start with '#' or contain digits in
        // positions where token names never do. Token names are pure
        // lowercase alpha + underscore, max length "border_focus" = 12.
        if (str.len == 0 or str.len > 16) return null;
        if (str[0] == '#') return null;

        return std.meta.stringToEnum(SemanticToken, str);
    }

    /// Resolve this token to a concrete Color from the given theme.
    /// Exhaustive switch — compiler forces update when tokens are added.
    pub fn resolve(self: SemanticToken, theme: *const Theme) Color {
        // CLAUDE.md #3: assert theme pointer is valid (non-null guaranteed by Zig).
        std.debug.assert(@intFromPtr(theme) != 0);

        return switch (self) {
            // Backgrounds
            .bg => theme.bg,
            .surface => theme.surface,
            .overlay => theme.overlay,

            // Accents
            .primary => theme.primary,
            .secondary => theme.secondary,
            .accent => theme.accent,
            .success => theme.success,
            .warning => theme.warning,
            .danger => theme.danger,

            // Text
            .text => theme.text,
            .subtext => theme.subtext,
            .muted => theme.muted,

            // Borders
            .border => theme.border,
            .border_focus => theme.border_focus,
        };
    }

    /// Return the token name as a string (for debug/logging).
    /// Zero-cost — returns a comptime string slice.
    pub fn name(self: SemanticToken) []const u8 {
        return @tagName(self);
    }
};

// =============================================================================
// ThemeColor
// =============================================================================

/// A color value that is either a concrete RGBA literal or a semantic
/// reference into the active theme. Replaces `Color` in `DrawCommand`
/// variants to enable theme-coherent AI-generated drawings.
pub const ThemeColor = union(enum) {
    /// Concrete RGBA color (from hex string like "FF6B35").
    literal: Color,
    /// Semantic theme reference (from token string like "primary").
    token: SemanticToken,

    /// Resolve to a concrete `Color`.
    /// Literals pass through unchanged. Tokens look up the active theme.
    pub fn resolve(self: ThemeColor, theme: *const Theme) Color {
        return switch (self) {
            .literal => |c| c,
            .token => |t| t.resolve(theme),
        };
    }

    /// Construct a ThemeColor from a literal Color value.
    pub fn fromLiteral(color: Color) ThemeColor {
        return .{ .literal = color };
    }

    /// Construct a ThemeColor from a semantic token.
    pub fn fromToken(token: SemanticToken) ThemeColor {
        return .{ .token = token };
    }

    /// Returns true if this is a semantic theme reference (not a literal).
    pub fn isToken(self: ThemeColor) bool {
        return switch (self) {
            .token => true,
            .literal => false,
        };
    }

    /// Returns true if this is a concrete literal color.
    pub fn isLiteral(self: ThemeColor) bool {
        return switch (self) {
            .literal => true,
            .token => false,
        };
    }

    /// Returns the semantic token if this is a token reference, null otherwise.
    pub fn getToken(self: ThemeColor) ?SemanticToken {
        return switch (self) {
            .token => |t| t,
            .literal => null,
        };
    }

    /// Returns the literal color if this is a literal, null otherwise.
    pub fn getLiteral(self: ThemeColor) ?Color {
        return switch (self) {
            .literal => |c| c,
            .token => null,
        };
    }
};

// =============================================================================
// Comptime Schema Helper
// =============================================================================

/// Comptime-generated comma-separated list of all semantic token names.
/// Used by `schema.zig` to populate the color field description so the
/// LLM sees exactly which tokens are available.
///
/// Output: "bg, surface, overlay, primary, secondary, accent, success, warning, danger, text, subtext, muted, border, border_focus"
pub const semantic_token_list: []const u8 = blk: {
    const fields = std.meta.fields(SemanticToken);
    var out: []const u8 = "";
    for (fields, 0..) |f, i| {
        out = out ++ f.name;
        if (i < fields.len - 1) {
            out = out ++ ", ";
        }
    }
    break :blk out;
};

// =============================================================================
// Compile-time Assertions (CLAUDE.md rules #3, #4)
// =============================================================================

comptime {
    // ThemeColor must be compact — it replaces Color (16 bytes) in DrawCommand.
    // Tagged union overhead: 16 bytes payload + tag + padding ≤ 20 bytes.
    std.debug.assert(@sizeOf(ThemeColor) <= 20);

    // SemanticToken must be a single byte.
    std.debug.assert(@sizeOf(SemanticToken) == 1);

    // Token count must match the 14 semantic color fields in Theme.
    std.debug.assert(SemanticToken.COUNT == 14);

    // Alignment should be reasonable for embedding in DrawCommand arrays.
    std.debug.assert(@alignOf(ThemeColor) <= 8);

    // The token list string must be non-empty.
    std.debug.assert(semantic_token_list.len > 0);

    // The token list must contain all 14 token names (13 commas = 14 items).
    {
        var comma_count: usize = 0;
        for (semantic_token_list) |ch| {
            if (ch == ',') comma_count += 1;
        }
        std.debug.assert(comma_count == SemanticToken.COUNT - 1);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "ThemeColor size fits budget" {
    try std.testing.expect(@sizeOf(ThemeColor) <= 20);
    try std.testing.expect(@sizeOf(SemanticToken) == 1);
}

test "SemanticToken count is 14" {
    try std.testing.expectEqual(@as(usize, 14), SemanticToken.COUNT);
}

test "SemanticToken.fromString parses all tokens" {
    const expected = [_]struct { str: []const u8, token: SemanticToken }{
        .{ .str = "bg", .token = .bg },
        .{ .str = "surface", .token = .surface },
        .{ .str = "overlay", .token = .overlay },
        .{ .str = "primary", .token = .primary },
        .{ .str = "secondary", .token = .secondary },
        .{ .str = "accent", .token = .accent },
        .{ .str = "success", .token = .success },
        .{ .str = "warning", .token = .warning },
        .{ .str = "danger", .token = .danger },
        .{ .str = "text", .token = .text },
        .{ .str = "subtext", .token = .subtext },
        .{ .str = "muted", .token = .muted },
        .{ .str = "border", .token = .border },
        .{ .str = "border_focus", .token = .border_focus },
    };

    // CLAUDE.md #3: assert we're testing all tokens.
    std.debug.assert(expected.len == SemanticToken.COUNT);

    for (expected) |e| {
        const result = SemanticToken.fromString(e.str);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(e.token, result.?);
    }
}

test "SemanticToken.fromString rejects hex colors" {
    try std.testing.expect(SemanticToken.fromString("FF6B35") == null);
    try std.testing.expect(SemanticToken.fromString("#FF6B35") == null);
    try std.testing.expect(SemanticToken.fromString("FFF") == null);
    try std.testing.expect(SemanticToken.fromString("000000") == null);
    try std.testing.expect(SemanticToken.fromString("#RRGGBB") == null);
    try std.testing.expect(SemanticToken.fromString("FF6B35CC") == null);
}

test "SemanticToken.fromString rejects unknown names" {
    try std.testing.expect(SemanticToken.fromString("purple") == null);
    try std.testing.expect(SemanticToken.fromString("background") == null);
    try std.testing.expect(SemanticToken.fromString("PRIMARY") == null);
    try std.testing.expect(SemanticToken.fromString("Primary") == null);
    try std.testing.expect(SemanticToken.fromString("text_color") == null);
}

test "SemanticToken.fromString rejects oversized strings" {
    try std.testing.expect(SemanticToken.fromString("this_is_way_too_long_to_be_a_token") == null);
}

test "SemanticToken.resolve against dark theme" {
    const theme = &Theme.dark;

    try std.testing.expectEqual(theme.bg, SemanticToken.bg.resolve(theme));
    try std.testing.expectEqual(theme.surface, SemanticToken.surface.resolve(theme));
    try std.testing.expectEqual(theme.overlay, SemanticToken.overlay.resolve(theme));
    try std.testing.expectEqual(theme.primary, SemanticToken.primary.resolve(theme));
    try std.testing.expectEqual(theme.secondary, SemanticToken.secondary.resolve(theme));
    try std.testing.expectEqual(theme.accent, SemanticToken.accent.resolve(theme));
    try std.testing.expectEqual(theme.success, SemanticToken.success.resolve(theme));
    try std.testing.expectEqual(theme.warning, SemanticToken.warning.resolve(theme));
    try std.testing.expectEqual(theme.danger, SemanticToken.danger.resolve(theme));
    try std.testing.expectEqual(theme.text, SemanticToken.text.resolve(theme));
    try std.testing.expectEqual(theme.subtext, SemanticToken.subtext.resolve(theme));
    try std.testing.expectEqual(theme.muted, SemanticToken.muted.resolve(theme));
    try std.testing.expectEqual(theme.border, SemanticToken.border.resolve(theme));
    try std.testing.expectEqual(theme.border_focus, SemanticToken.border_focus.resolve(theme));
}

test "SemanticToken.resolve against light theme" {
    const theme = &Theme.light;

    try std.testing.expectEqual(theme.primary, SemanticToken.primary.resolve(theme));
    try std.testing.expectEqual(theme.bg, SemanticToken.bg.resolve(theme));
    try std.testing.expectEqual(theme.text, SemanticToken.text.resolve(theme));
}

test "SemanticToken.resolve differs between light and dark" {
    const light = &Theme.light;
    const dark = &Theme.dark;

    // Primary should differ between themes.
    const light_primary = SemanticToken.primary.resolve(light);
    const dark_primary = SemanticToken.primary.resolve(dark);
    try std.testing.expect(light_primary.r != dark_primary.r or
        light_primary.g != dark_primary.g or
        light_primary.b != dark_primary.b);

    // Background should differ.
    const light_bg = SemanticToken.bg.resolve(light);
    const dark_bg = SemanticToken.bg.resolve(dark);
    try std.testing.expect(light_bg.r != dark_bg.r);
}

test "ThemeColor.fromLiteral preserves color" {
    const red = Color.hex(0xFF0000);
    const tc = ThemeColor.fromLiteral(red);

    try std.testing.expect(tc.isLiteral());
    try std.testing.expect(!tc.isToken());
    try std.testing.expect(tc.getToken() == null);

    const lit = tc.getLiteral().?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lit.r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lit.g, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lit.b, 0.01);
}

test "ThemeColor.fromToken stores token" {
    const tc = ThemeColor.fromToken(.primary);

    try std.testing.expect(tc.isToken());
    try std.testing.expect(!tc.isLiteral());
    try std.testing.expect(tc.getLiteral() == null);
    try std.testing.expectEqual(SemanticToken.primary, tc.getToken().?);
}

test "ThemeColor.resolve literal passes through unchanged" {
    const blue = Color.hex(0x0000FF);
    const tc = ThemeColor.fromLiteral(blue);
    const theme = &Theme.dark;

    const resolved = tc.resolve(theme);
    try std.testing.expectApproxEqAbs(blue.r, resolved.r, 0.001);
    try std.testing.expectApproxEqAbs(blue.g, resolved.g, 0.001);
    try std.testing.expectApproxEqAbs(blue.b, resolved.b, 0.001);
    try std.testing.expectApproxEqAbs(blue.a, resolved.a, 0.001);
}

test "ThemeColor.resolve token returns theme color" {
    const tc = ThemeColor.fromToken(.primary);

    const dark_color = tc.resolve(&Theme.dark);
    try std.testing.expectEqual(Theme.dark.primary, dark_color);

    const light_color = tc.resolve(&Theme.light);
    try std.testing.expectEqual(Theme.light.primary, light_color);
}

test "SemanticToken.name returns correct strings" {
    try std.testing.expectEqualStrings("bg", SemanticToken.bg.name());
    try std.testing.expectEqualStrings("primary", SemanticToken.primary.name());
    try std.testing.expectEqualStrings("border_focus", SemanticToken.border_focus.name());
}

test "semantic_token_list contains all tokens" {
    const fields = std.meta.fields(SemanticToken);
    inline for (fields) |f| {
        try std.testing.expect(std.mem.indexOf(u8, semantic_token_list, f.name) != null);
    }
}

test "semantic_token_list has correct format" {
    // Should start with "bg" and end with "border_focus".
    try std.testing.expect(std.mem.startsWith(u8, semantic_token_list, "bg"));
    try std.testing.expect(std.mem.endsWith(u8, semantic_token_list, "border_focus"));
}
