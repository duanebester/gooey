//! AI Integration Module
//!
//! Canvas command buffer for LLM-driven drawing. Exposes Gooey's drawing
//! primitives as a structured command interface that AI models can target.
//!
//! Phase 1: Core types (DrawCommand, TextPool)
//! Phase 2: Replay engine (AiCanvas)
//! Phase 3: JSON parser (parseCommand)
//! Phase 4: Schema generation (tool_schema)
//! Phase 5: Theme-aware colors (ThemeColor, SemanticToken)

const draw_command = @import("draw_command.zig");
const text_pool = @import("text_pool.zig");
const ai_canvas = @import("ai_canvas.zig");
const json_parser = @import("json_parser.zig");
const schema = @import("schema.zig");
const theme_color = @import("theme_color.zig");

/// Tagged union mapping 1:1 to DrawContext methods (11 variants).
pub const DrawCommand = draw_command.DrawCommand;

/// Hard cap on draw commands per frame/batch.
pub const MAX_DRAW_COMMANDS = draw_command.MAX_DRAW_COMMANDS;

/// Fixed-capacity string arena for draw command text.
pub const TextPool = text_pool.TextPool;

/// Total byte capacity for pooled strings.
pub const MAX_TEXT_POOL_SIZE = text_pool.MAX_TEXT_POOL_SIZE;

/// Maximum number of distinct string entries.
pub const MAX_TEXT_ENTRIES = text_pool.MAX_TEXT_ENTRIES;

/// Maximum byte length for a single string entry.
pub const MAX_TEXT_ENTRY_SIZE = text_pool.MAX_TEXT_ENTRY_SIZE;

/// Replay engine: owns the command buffer and text pool, provides mutation
/// API (for parser/transport) and replay API (for paint callback).
/// ~280KB — must live in global `var` state, never on the stack.
pub const AiCanvas = ai_canvas.AiCanvas;

/// Parse a single JSON line into a DrawCommand.
/// For text commands, pushes the string into the provided TextPool.
/// Returns null on malformed input, unknown tools, or missing fields.
pub const parseCommand = json_parser.parseCommand;

/// Maximum byte length for a single JSON input line.
pub const MAX_JSON_LINE_SIZE = json_parser.MAX_JSON_LINE_SIZE;

/// Comptime-generated JSON tool schema array derived from DrawCommand.
/// Zero runtime cost — this is a string literal baked into the binary.
pub const tool_schema = schema.tool_schema;

/// Number of tools in the generated schema (matches DrawCommand variant count).
pub const TOOL_COUNT = schema.TOOL_COUNT;

/// A color that is either a concrete RGBA literal or a semantic theme
/// reference (e.g. "primary", "surface"). Theme tokens resolve against
/// the active `Theme` at replay time — AI-drawn content automatically
/// adapts to light/dark mode and custom themes.
pub const ThemeColor = theme_color.ThemeColor;

/// Enum of semantic color slots mirroring `Theme` struct fields 1:1.
/// Used inside `ThemeColor.token` variants and for parsing color strings
/// like `"primary"` from JSON commands.
pub const SemanticToken = theme_color.SemanticToken;

/// Comptime-generated comma-separated list of all semantic token names.
/// Useful for building prompts or documentation that enumerate valid tokens.
pub const semantic_token_list = theme_color.semantic_token_list;

test {
    @import("std").testing.refAllDecls(@This());
}
