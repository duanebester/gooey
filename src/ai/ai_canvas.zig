//! AiCanvas — Replay engine for AI-driven drawing commands.
//!
//! Owns the command buffer and text pool. Provides a mutation API (for the
//! parser/transport layer) and a replay API (for the comptime paint callback).
//!
//! At ~280KB this struct MUST live in global `var` state — never on the stack.
//! On WASM the 1MB stack budget would be instantly blown (CLAUDE.md rule #14).
//!
//! Native uses triple-buffered global instances (~840KB total); WASM uses a
//! single global instance (~280KB). See Phase 5 for the transport wiring.

const std = @import("std");
const DrawCommand = @import("draw_command.zig").DrawCommand;
const MAX_DRAW_COMMANDS = @import("draw_command.zig").MAX_DRAW_COMMANDS;
const TextPool = @import("text_pool.zig").TextPool;
const Color = @import("../core/geometry.zig").Color;
const ThemeColor = @import("theme_color.zig").ThemeColor;
const SemanticToken = @import("theme_color.zig").SemanticToken;
const ui = @import("../ui/mod.zig");
const Theme = ui.Theme;

// =============================================================================
// AiCanvas
// =============================================================================

pub const AiCanvas = struct {
    /// Fixed-capacity command buffer. Undefined init — no zero-fill needed.
    /// Only `commands[0..command_count]` contains valid data.
    commands: [MAX_DRAW_COMMANDS]DrawCommand = undefined,

    /// Number of valid commands in the buffer.
    command_count: usize = 0,

    /// String arena for text draw commands (indexed by `text_idx: u16`).
    texts: TextPool = .{},

    /// Logical canvas dimensions (used for background fills and layout hints).
    canvas_width: f32 = 800,
    canvas_height: f32 = 600,

    /// Default background color applied before any commands replay.
    /// Uses `ThemeColor` so it can reference a semantic token (e.g. `.bg`)
    /// that adapts to the active theme automatically.
    background_color: ThemeColor = ThemeColor.fromLiteral(Color.hex(0x1a1a2e)),

    const Self = @This();

    // =========================================================================
    // Mutation API (called by transport/parser layer)
    // =========================================================================

    /// Push a command onto the buffer.
    ///
    /// Returns `true` on success, `false` if the buffer is full. In debug
    /// builds an assertion fires on overflow so the developer notices
    /// immediately — in release the command is silently dropped (fail-fast,
    /// no crash). Handles the negative space per CLAUDE.md rule #11.
    pub fn pushCommand(self: *Self, cmd: DrawCommand) bool {
        // CLAUDE.md #3: assert at API boundary + #11: negative space.
        std.debug.assert(self.command_count <= MAX_DRAW_COMMANDS);

        if (self.command_count >= MAX_DRAW_COMMANDS) return false;

        // Assert text references are valid before storing (CLAUDE.md #3 pair).
        if (cmd.textIdx()) |idx| {
            std.debug.assert(idx < self.texts.entryCount());
        }

        self.commands[self.command_count] = cmd;
        self.command_count += 1;
        return true;
    }

    /// Push a string into the text pool and return its index.
    ///
    /// Returns `null` if the pool is full (entry count or byte capacity
    /// exhausted). Callers should handle null by skipping the text command.
    pub fn pushText(self: *Self, text: []const u8) ?u16 {
        // CLAUDE.md #3: assert reasonable input.
        std.debug.assert(text.len <= @import("text_pool.zig").MAX_TEXT_ENTRY_SIZE);
        return self.texts.push(text);
    }

    /// Reset all state for the next batch of commands.
    ///
    /// O(1) — counters reset, buffer contents become garbage.
    pub fn clearAll(self: *Self) void {
        // CLAUDE.md #3: assert we're in a valid state before clearing.
        std.debug.assert(self.command_count <= MAX_DRAW_COMMANDS);
        self.command_count = 0;
        self.texts.clear();
        // CLAUDE.md #3: assert post-condition.
        std.debug.assert(self.command_count == 0);
    }

    // =========================================================================
    // Query API
    // =========================================================================

    /// Returns the number of commands currently buffered.
    pub fn commandCount(self: *const Self) usize {
        std.debug.assert(self.command_count <= MAX_DRAW_COMMANDS);
        return self.command_count;
    }

    /// Returns remaining command capacity.
    pub fn commandsRemaining(self: *const Self) usize {
        std.debug.assert(self.command_count <= MAX_DRAW_COMMANDS);
        return MAX_DRAW_COMMANDS - self.command_count;
    }

    /// Returns true if the command buffer is at capacity.
    pub fn isFull(self: *const Self) bool {
        std.debug.assert(self.command_count <= MAX_DRAW_COMMANDS);
        return self.command_count >= MAX_DRAW_COMMANDS;
    }

    // =========================================================================
    // Replay API (called by the comptime paint callback)
    // =========================================================================

    /// Replay all buffered commands into a DrawContext.
    ///
    /// This is the bridge between the AI command buffer and Gooey's
    /// rendering pipeline. Called once per frame from the paint callback.
    ///
    /// The `theme` parameter enables semantic `ThemeColor` tokens (e.g.
    /// "primary", "surface") to resolve to concrete colors at render time.
    /// This means AI-drawn content automatically adapts to light/dark mode
    /// and custom themes without re-parsing commands.
    ///
    /// Parameter order inconsistencies in DrawContext are handled here —
    /// each arm maps DrawCommand's consistent field names to the actual
    /// DrawContext method signature. See the mapping table in AI_NATIVE_IMPL.md.
    pub fn replay(self: *const Self, ctx: *ui.DrawContext, theme: *const Theme) void {
        // CLAUDE.md #3: assert invariants at entry.
        std.debug.assert(self.command_count <= MAX_DRAW_COMMANDS);

        const w = ctx.width();
        const h = ctx.height();

        // CLAUDE.md #3: assert canvas dimensions are sane.
        std.debug.assert(w >= 0 and h >= 0);

        // Background fill — always first so commands draw on top.
        // Resolve ThemeColor against the active theme.
        const bg = self.background_color.resolve(theme);
        ctx.fillRect(0, 0, w, h, bg);

        // Replay every command via exhaustive switch.
        for (self.commands[0..self.command_count]) |cmd| {
            self.replayOne(ctx, cmd, w, h, theme);
        }
    }

    /// Replay a single command. Split from `replay` to keep functions
    /// under the 70-line limit (CLAUDE.md rule #5) and to isolate
    /// the parameter-order mapping logic.
    fn replayOne(
        self: *const Self,
        ctx: *ui.DrawContext,
        cmd: DrawCommand,
        canvas_w: f32,
        canvas_h: f32,
        theme: *const Theme,
    ) void {
        // CLAUDE.md #3: assert context validity.
        std.debug.assert(canvas_w >= 0 and canvas_h >= 0);

        switch (cmd) {
            // === Fills ===
            .fill_rect => |c| ctx.fillRect(c.x, c.y, c.w, c.h, c.color.resolve(theme)),
            .fill_rounded_rect => |c| ctx.fillRoundedRect(c.x, c.y, c.w, c.h, c.radius, c.color.resolve(theme)),
            .fill_circle => |c| ctx.fillCircle(c.cx, c.cy, c.radius, c.color.resolve(theme)),
            .fill_ellipse => |c| ctx.fillEllipse(c.cx, c.cy, c.rx, c.ry, c.color.resolve(theme)),
            .fill_triangle => |c| ctx.fillTriangle(c.x1, c.y1, c.x2, c.y2, c.x3, c.y3, c.color.resolve(theme)),

            // === Strokes / Lines ===
            // NOTE: strokeRect takes (x, y, w, h, color, width) — color BEFORE width
            .stroke_rect => |c| ctx.strokeRect(c.x, c.y, c.w, c.h, c.color.resolve(theme), c.width),
            // NOTE: strokeCircle takes (cx, cy, radius, width, color) — width BEFORE color
            .stroke_circle => |c| ctx.strokeCircle(c.cx, c.cy, c.radius, c.width, c.color.resolve(theme)),
            // NOTE: line takes (x1, y1, x2, y2, width, color) — width BEFORE color
            .line => |c| ctx.line(c.x1, c.y1, c.x2, c.y2, c.width, c.color.resolve(theme)),

            // === Text ===
            .draw_text => |c| self.replayDrawText(ctx, c, theme),
            .draw_text_centered => |c| self.replayDrawTextCentered(ctx, c, theme),

            // === Control ===
            .set_background => |c| ctx.fillRect(0, 0, canvas_w, canvas_h, c.color.resolve(theme)),
        }
    }

    /// Replay a draw_text command. Separated to keep replayOne concise
    /// and to isolate the text pool lookup + assertion.
    fn replayDrawText(
        self: *const Self,
        ctx: *ui.DrawContext,
        c: DrawCommand.DrawText,
        theme: *const Theme,
    ) void {
        // CLAUDE.md #3 + #11: assert text_idx is valid before pool lookup.
        std.debug.assert(c.text_idx < self.texts.entryCount());
        const text = self.texts.get(c.text_idx);
        _ = ctx.drawText(text, c.x, c.y, c.color.resolve(theme), c.font_size);
    }

    /// Replay a draw_text_centered command.
    fn replayDrawTextCentered(
        self: *const Self,
        ctx: *ui.DrawContext,
        c: DrawCommand.DrawTextCentered,
        theme: *const Theme,
    ) void {
        // CLAUDE.md #3 + #11: assert text_idx is valid before pool lookup.
        std.debug.assert(c.text_idx < self.texts.entryCount());
        const text = self.texts.get(c.text_idx);
        _ = ctx.drawTextVCentered(text, c.x, c.y_center, c.color.resolve(theme), c.font_size);
    }
};

// =============================================================================
// Compile-time Assertions (CLAUDE.md rules #3, #4)
// =============================================================================

comptime {
    // Size budget: AiCanvas must stay under 300KB.
    // commands (4096 × ≤64B ≈ 256KB) + TextPool (~17KB) + fields (~20B) ≈ 273KB
    std.debug.assert(@sizeOf(AiCanvas) < 300 * 1024);

    // Sanity: AiCanvas must be larger than its command buffer alone.
    // This catches accidental removal of fields.
    std.debug.assert(@sizeOf(AiCanvas) > MAX_DRAW_COMMANDS * @sizeOf(DrawCommand));

    // Alignment should be reasonable — no hidden padding explosions.
    std.debug.assert(@alignOf(AiCanvas) <= 16);
}

// =============================================================================
// Tests
// =============================================================================

test "AiCanvas size under 300KB" {
    try std.testing.expect(@sizeOf(AiCanvas) < 300 * 1024);
}

test "AiCanvas default state" {
    var canvas = AiCanvas{};
    try std.testing.expectEqual(@as(usize, 0), canvas.commandCount());
    try std.testing.expectEqual(@as(usize, MAX_DRAW_COMMANDS), canvas.commandsRemaining());
    try std.testing.expect(!canvas.isFull());
    try std.testing.expectApproxEqAbs(@as(f32, 800), canvas.canvas_width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 600), canvas.canvas_height, 0.001);
}

test "AiCanvas pushCommand increments count" {
    var canvas = AiCanvas{};
    const red = ThemeColor.fromLiteral(Color.hex(0xFF0000));

    const ok = canvas.pushCommand(.{ .fill_rect = .{
        .x = 10,
        .y = 20,
        .w = 100,
        .h = 50,
        .color = red,
    } });

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), canvas.commandCount());
    try std.testing.expectEqual(@as(usize, MAX_DRAW_COMMANDS - 1), canvas.commandsRemaining());
}

test "AiCanvas pushCommand stores correct data" {
    var canvas = AiCanvas{};
    const blue = ThemeColor.fromLiteral(Color.hex(0x0000FF));

    _ = canvas.pushCommand(.{ .fill_circle = .{
        .cx = 50,
        .cy = 75,
        .radius = 25,
        .color = blue,
    } });

    const cmd = canvas.commands[0];
    switch (cmd) {
        .fill_circle => |c| {
            try std.testing.expectApproxEqAbs(@as(f32, 50), c.cx, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 75), c.cy, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 25), c.radius, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "AiCanvas multiple commands maintain order" {
    var canvas = AiCanvas{};
    const white = ThemeColor.fromLiteral(Color.hex(0xFFFFFF));

    _ = canvas.pushCommand(.{ .fill_rect = .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = white } });
    _ = canvas.pushCommand(.{ .fill_circle = .{ .cx = 5, .cy = 5, .radius = 3, .color = white } });
    _ = canvas.pushCommand(.{ .line = .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .width = 2, .color = white } });

    try std.testing.expectEqual(@as(usize, 3), canvas.commandCount());

    // Verify order is preserved.
    switch (canvas.commands[0]) {
        .fill_rect => {},
        else => return error.TestUnexpectedResult,
    }
    switch (canvas.commands[1]) {
        .fill_circle => {},
        else => return error.TestUnexpectedResult,
    }
    switch (canvas.commands[2]) {
        .line => {},
        else => return error.TestUnexpectedResult,
    }
}

test "AiCanvas clearAll resets everything" {
    var canvas = AiCanvas{};
    const green = ThemeColor.fromLiteral(Color.hex(0x00FF00));

    _ = canvas.pushText("hello");
    _ = canvas.pushCommand(.{ .fill_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = green } });
    _ = canvas.pushCommand(.{ .fill_circle = .{ .cx = 0, .cy = 0, .radius = 1, .color = green } });

    try std.testing.expectEqual(@as(usize, 2), canvas.commandCount());

    canvas.clearAll();

    try std.testing.expectEqual(@as(usize, 0), canvas.commandCount());
    try std.testing.expectEqual(@as(usize, MAX_DRAW_COMMANDS), canvas.commandsRemaining());
    try std.testing.expect(!canvas.isFull());
    try std.testing.expectEqual(@as(u16, 0), canvas.texts.entryCount());
}

test "AiCanvas clearAll allows reuse" {
    var canvas = AiCanvas{};
    const red = ThemeColor.fromLiteral(Color.hex(0xFF0000));

    _ = canvas.pushCommand(.{ .fill_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = red } });
    canvas.clearAll();

    // Should be able to push again after clear.
    const ok = canvas.pushCommand(.{ .fill_circle = .{ .cx = 5, .cy = 5, .radius = 3, .color = red } });
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), canvas.commandCount());

    switch (canvas.commands[0]) {
        .fill_circle => {},
        else => return error.TestUnexpectedResult,
    }
}

test "AiCanvas overflow returns false" {
    var canvas = AiCanvas{};
    const white = ThemeColor.fromLiteral(Color.hex(0xFFFFFF));

    // Fill to capacity.
    var i: usize = 0;
    while (i < MAX_DRAW_COMMANDS) : (i += 1) {
        const ok = canvas.pushCommand(.{ .set_background = .{ .color = white } });
        try std.testing.expect(ok);
    }

    try std.testing.expect(canvas.isFull());
    try std.testing.expectEqual(@as(usize, 0), canvas.commandsRemaining());

    // One more must return false — no crash.
    const overflow = canvas.pushCommand(.{ .set_background = .{ .color = white } });
    try std.testing.expect(!overflow);
    try std.testing.expectEqual(@as(usize, MAX_DRAW_COMMANDS), canvas.commandCount());
}

test "AiCanvas pushText roundtrip" {
    var canvas = AiCanvas{};

    const idx0 = canvas.pushText("Hello, AI!").?;
    const idx1 = canvas.pushText("Second line").?;

    try std.testing.expectEqual(@as(u16, 0), idx0);
    try std.testing.expectEqual(@as(u16, 1), idx1);

    try std.testing.expectEqualStrings("Hello, AI!", canvas.texts.get(idx0));
    try std.testing.expectEqualStrings("Second line", canvas.texts.get(idx1));
}

test "AiCanvas text command integration" {
    var canvas = AiCanvas{};
    const white = ThemeColor.fromLiteral(Color.hex(0xFFFFFF));

    // Push text first, then reference it in a command.
    const idx = canvas.pushText("Score: 42").?;
    const ok = canvas.pushCommand(.{ .draw_text = .{
        .text_idx = idx,
        .x = 10,
        .y = 20,
        .color = white,
        .font_size = 16,
    } });

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), canvas.commandCount());

    // Verify the command stores the correct text_idx.
    switch (canvas.commands[0]) {
        .draw_text => |c| {
            try std.testing.expectEqual(@as(u16, idx), c.text_idx);
            try std.testing.expectEqualStrings("Score: 42", canvas.texts.get(c.text_idx));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "AiCanvas text centered command integration" {
    var canvas = AiCanvas{};
    const black = ThemeColor.fromLiteral(Color.hex(0x000000));

    const idx = canvas.pushText("Centered!").?;
    _ = canvas.pushCommand(.{ .draw_text_centered = .{
        .text_idx = idx,
        .x = 100,
        .y_center = 300,
        .color = black,
        .font_size = 24,
    } });

    switch (canvas.commands[0]) {
        .draw_text_centered => |c| {
            try std.testing.expectEqual(@as(u16, idx), c.text_idx);
            try std.testing.expectApproxEqAbs(@as(f32, 300), c.y_center, 0.001);
            try std.testing.expectEqualStrings("Centered!", canvas.texts.get(c.text_idx));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "AiCanvas all 11 command variants push successfully" {
    var canvas = AiCanvas{};
    const c = ThemeColor.fromLiteral(Color.hex(0xABCDEF));

    const text_idx = canvas.pushText("test").?;

    const all_commands = [_]DrawCommand{
        .{ .fill_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = c } },
        .{ .fill_rounded_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .radius = 4, .color = c } },
        .{ .fill_circle = .{ .cx = 0, .cy = 0, .radius = 1, .color = c } },
        .{ .fill_ellipse = .{ .cx = 0, .cy = 0, .rx = 1, .ry = 2, .color = c } },
        .{ .fill_triangle = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .x3 = 0, .y3 = 1, .color = c } },
        .{ .stroke_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .width = 2, .color = c } },
        .{ .stroke_circle = .{ .cx = 0, .cy = 0, .radius = 1, .width = 2, .color = c } },
        .{ .line = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1, .width = 1, .color = c } },
        .{ .draw_text = .{ .text_idx = text_idx, .x = 0, .y = 0, .color = c, .font_size = 12 } },
        .{ .draw_text_centered = .{ .text_idx = text_idx, .x = 0, .y_center = 0, .color = c, .font_size = 12 } },
        .{ .set_background = .{ .color = c } },
    };

    for (all_commands) |cmd| {
        const ok = canvas.pushCommand(cmd);
        try std.testing.expect(ok);
    }

    try std.testing.expectEqual(@as(usize, 11), canvas.commandCount());
}

test "AiCanvas background_color default is literal" {
    const canvas = AiCanvas{};
    // Default background is a literal 0x1a1a2e (dark blue-grey).
    try std.testing.expect(canvas.background_color.isLiteral());
    const bg = canvas.background_color.getLiteral().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0x1a) / 255.0, bg.r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0x1a) / 255.0, bg.g, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0x2e) / 255.0, bg.b, 0.01);
}

test "AiCanvas background_color can be theme token" {
    var canvas = AiCanvas{};
    canvas.background_color = ThemeColor.fromToken(.bg);

    try std.testing.expect(canvas.background_color.isToken());
    try std.testing.expectEqual(SemanticToken.bg, canvas.background_color.getToken().?);

    // Resolve against dark theme.
    const resolved = canvas.background_color.resolve(&Theme.dark);
    try std.testing.expectEqual(Theme.dark.bg, resolved);

    // Resolve against light theme — should be different.
    const resolved_light = canvas.background_color.resolve(&Theme.light);
    try std.testing.expectEqual(Theme.light.bg, resolved_light);
    try std.testing.expect(resolved.r != resolved_light.r);
}

test "AiCanvas commands with theme tokens" {
    var canvas = AiCanvas{};

    // Push commands using theme tokens.
    _ = canvas.pushCommand(.{ .set_background = .{ .color = ThemeColor.fromToken(.bg) } });
    _ = canvas.pushCommand(.{ .fill_rect = .{
        .x = 10,
        .y = 20,
        .w = 100,
        .h = 50,
        .color = ThemeColor.fromToken(.primary),
    } });
    _ = canvas.pushCommand(.{ .fill_circle = .{
        .cx = 50,
        .cy = 50,
        .radius = 25,
        .color = ThemeColor.fromToken(.accent),
    } });

    try std.testing.expectEqual(@as(usize, 3), canvas.commandCount());

    // Verify tokens are stored correctly.
    try std.testing.expect(canvas.commands[0].getColor().isToken());
    try std.testing.expectEqual(SemanticToken.bg, canvas.commands[0].getColor().getToken().?);
    try std.testing.expect(canvas.commands[1].getColor().isToken());
    try std.testing.expectEqual(SemanticToken.primary, canvas.commands[1].getColor().getToken().?);
    try std.testing.expect(canvas.commands[2].getColor().isToken());
    try std.testing.expectEqual(SemanticToken.accent, canvas.commands[2].getColor().getToken().?);
}

test "AiCanvas mixed literal and token commands" {
    var canvas = AiCanvas{};

    // Mix of literal hex colors and semantic tokens.
    _ = canvas.pushCommand(.{ .set_background = .{ .color = ThemeColor.fromToken(.bg) } });
    _ = canvas.pushCommand(.{ .fill_rect = .{
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 50,
        .color = ThemeColor.fromLiteral(Color.hex(0xFF6B35)),
    } });
    _ = canvas.pushCommand(.{ .stroke_rect = .{
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 50,
        .width = 2,
        .color = ThemeColor.fromToken(.border),
    } });

    try std.testing.expectEqual(@as(usize, 3), canvas.commandCount());

    // First is token, second is literal, third is token.
    try std.testing.expect(canvas.commands[0].getColor().isToken());
    try std.testing.expect(canvas.commands[1].getColor().isLiteral());
    try std.testing.expect(canvas.commands[2].getColor().isToken());
}
