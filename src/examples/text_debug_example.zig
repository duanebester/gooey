//! Text Debug Example
//!
//! A simple example to debug and compare text rendering between native and web.
//! Run this on both platforms to compare glyph metrics and advances for
//! words that may have rendering issues (like "Tell" and "Your").
//!
//! Usage:
//!   Native: zig build run-text-debug
//!   Web:    zig build wasm-text && open web/index.html

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const text_mod = gooey.text;
const text_debug = text_mod.text_debug;

// Test words that have shown rendering issues
const TEST_WORDS = [_][]const u8{
    "Tell",
    "Your",
    "Hello",
    "Well",
    "fill",
    "all",
    "ell",
    "ll",
};

// =============================================================================
// Cross-platform Debug Logging
// =============================================================================

/// Debug log function that works on both native and WASM platforms
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (platform.is_wasm) {
        platform.web.imports.log(fmt, args);
    } else {
        std.debug.print(fmt ++ "\n", args);
    }
}

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    debug_logged: bool = false,

    pub fn triggerDebugLog(self: *AppState) void {
        self.debug_logged = false;
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Text Debug - " ++ text_debug.platform_name,
    .width = 600,
    .height = 500,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    // Log debug info once on startup
    if (!s.debug_logged) {
        logDebugInfo(cx);
        s.debug_logged = true;
    }

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 20 },
        .gap = 16,
        .direction = .column,
        .background = ui.Color.rgb(0.1, 0.1, 0.12),
    }, .{
        // Header
        ui.text("Text Rendering Debug (" ++ text_debug.platform_name ++ ")", .{
            .color = ui.Color.rgb(0.9, 0.9, 0.95),
            .size = 24,
        }),

        // Test words display
        WordsDisplay{},

        // Large sample text
        SampleText{},

        // Button to re-log debug
        ui.box(.{ .gap = 12 }, .{
            Button{
                .label = "Log Debug Info to Console",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.triggerDebugLog),
            },
        }),

        // Instructions
        Instructions{},
    }));
}

// =============================================================================
// Components
// =============================================================================

const WordsDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .padding = .{ .all = 16 },
            .gap = 16,
            .direction = .row,
            .background = ui.Color.rgb(0.15, 0.15, 0.18),
            .corner_radius = 8,
        }, .{
            // Display each test word
            WordBox{ .word = "Tell" },
            WordBox{ .word = "Your" },
            WordBox{ .word = "Hello" },
            WordBox{ .word = "Well" },
            WordBox{ .word = "fill" },
            WordBox{ .word = "all" },
            WordBox{ .word = "ell" },
            WordBox{ .word = "ll" },
        }));
    }
};

const WordBox = struct {
    word: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = ui.Color.rgb(0.2, 0.2, 0.25),
            .corner_radius = 4,
        }, .{
            ui.text(self.word, .{
                .color = ui.Color.rgb(0.95, 0.95, 1.0),
                .size = 18,
            }),
        }));
    }
};

const SampleText = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .padding = .{ .all = 24 },
            .gap = 16,
            .direction = .column,
            .background = ui.Color.rgb(0.08, 0.08, 0.1),
            .corner_radius = 8,
        }, .{
            // Large "Tell" - the problematic word
            ui.text("Tell Your Story", .{
                .color = ui.Color.rgb(1.0, 1.0, 1.0),
                .size = 48,
            }),

            // Medium size
            ui.text("Hello World - Well done - fill all", .{
                .color = ui.Color.rgb(0.8, 0.8, 0.85),
                .size = 24,
            }),

            // Small size for comparison
            ui.text("The quick brown fox jumps over the lazy dog", .{
                .color = ui.Color.rgb(0.6, 0.6, 0.65),
                .size = 14,
            }),
        }));
    }
};

const Instructions = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .gap = 4,
            .direction = .column,
        }, .{
            ui.text("Instructions:", .{
                .color = ui.Color.rgb(0.6, 0.6, 0.65),
                .size = 14,
            }),
            ui.text("1. Run this example on both native and web", .{
                .color = ui.Color.rgb(0.5, 0.5, 0.55),
                .size = 12,
            }),
            ui.text("2. Compare glyph advances in console output", .{
                .color = ui.Color.rgb(0.5, 0.5, 0.55),
                .size = 12,
            }),
            ui.text("3. Look for differences in x_advance values", .{
                .color = ui.Color.rgb(0.5, 0.5, 0.55),
                .size = 12,
            }),
            ui.text("4. Check if 'Tell' looks like 'Te ll' on web", .{
                .color = ui.Color.rgb(0.5, 0.5, 0.55),
                .size = 12,
            }),
        }));
    }
};

// =============================================================================
// Debug Logging
// =============================================================================

fn logDebugInfo(cx: *Cx) void {
    const text_system = cx.gooey().getTextSystem();

    debugLog("", .{});
    debugLog("========================================", .{});
    debugLog("  Text Debug - {s} platform", .{text_debug.platform_name});
    debugLog("========================================", .{});

    // Log font metrics
    if (text_system.getMetrics()) |metrics| {
        text_debug.logFontMetrics(metrics);
    }

    // Log shaped runs for each test word
    for (TEST_WORDS) |word| {
        text_debug.debugShapeText(text_system, word) catch |err| {
            debugLog("Error shaping '{s}': {}", .{ word, err });
        };
    }

    // Log glyph advances in a compact format for easy comparison
    debugLog("", .{});
    debugLog("=== Compact Advance Comparison ===", .{});

    for (TEST_WORDS) |word| {
        text_debug.logGlyphAdvances(text_system, word) catch {};
    }

    debugLog("", .{});
    debugLog("========================================", .{});
    debugLog("  End of debug output", .{});
    debugLog("========================================", .{});
}
