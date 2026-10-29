//! Clipboard Example
//!
//! A manual check of the system clipboard through the text widgets: copy and
//! paste between this window and any other application. The edit shortcuts
//! use the platform's command modifier (Ctrl on Windows, Cmd on macOS).
//!
//! Demonstrates:
//! - Copy, cut, paste, select all, undo, and redo in `TextInput`
//! - The same in `TextArea`, where multi-line text crosses the clipboard
//! - Line-ending normalization: text pasted from a CR LF application such as
//!   Notepad arrives with LF only, so the CR count below stays at zero

const std = @import("std");

const gooey = @import("gooey");
const components = @import("gooey-components");
const platform = gooey.platform;

/// Route std.log through the console on WASM, default logFn on native.
pub const std_options = gooey.std_options;

const ui = gooey.ui;
const Cx = gooey.Cx;
const TextArea = components.TextArea;
const TextInput = components.TextInput;

const muted = ui.Color.rgb(0.4, 0.4, 0.45);
const ink = ui.Color.rgb(0.1, 0.1, 0.15);

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    /// Bound to the single-line input.
    line: []const u8 = "Copy me, or paste over me.",
    /// Bound to the multi-line area.
    notes: []const u8 = "Line one\nLine two\nLine three",
};

/// Bytes, line breaks, and carriage returns in `text`. Pure so the
/// normalization the window displays is testable without a clipboard.
const TextStats = struct {
    byte_count: usize,
    line_feed_count: usize,
    carriage_return_count: usize,

    fn of(text: []const u8) TextStats {
        return .{
            .byte_count = text.len,
            .line_feed_count = std.mem.countScalar(u8, text, '\n'),
            .carriage_return_count = std.mem.countScalar(u8, text, '\r'),
        };
    }
};

// =============================================================================
// Entry Point
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .limits = .small,
    .title = "Clipboard",
    .width = 560,
    .height = 520,
});

// Force type analysis — triggers @export on WASM.
comptime {
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;
    return App.main(init);
}

// =============================================================================
// Render
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);

    cx.render(ui.root(.{
        .direction = .column,
        .padding = .{ .all = 24 },
        .gap = 14,
        .background = ui.Color.rgb(0.96, 0.96, 0.97),
    }, .{
        ui.text("Clipboard", .{ .size = 28, .color = ink }),
        ui.text(
            "Ctrl+C, Ctrl+X, Ctrl+V, Ctrl+A, Ctrl+Z (Cmd on macOS).",
            .{ .size = 14, .color = muted },
        ),
        ui.text("Single line", .{ .size = 16, .color = ink }),
        TextInput{
            .id = "clipboard-line",
            .placeholder = "Paste here",
            .bind = &s.line,
            .width = 512,
        },
        StatsRow{ .stats = TextStats.of(s.line) },
        ui.text("Multi-line", .{ .size = 16, .color = ink }),
        TextArea{
            .id = "clipboard-notes",
            .placeholder = "Paste multi-line text here",
            .bind = &s.notes,
            .width = 512,
            .height = 180,
        },
        StatsRow{ .stats = TextStats.of(s.notes) },
    }));
}

const StatsRow = struct {
    stats: TextStats,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.textFmt("{d} bytes, {d} LF, {d} CR", .{
            self.stats.byte_count,
            self.stats.line_feed_count,
            self.stats.carriage_return_count,
        }, .{ .size = 13, .color = muted }));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "text stats count bytes, line feeds, and carriage returns" {
    const stats = TextStats.of("a\r\nb\nc");
    try std.testing.expectEqual(@as(usize, 6), stats.byte_count);
    try std.testing.expectEqual(@as(usize, 2), stats.line_feed_count);
    try std.testing.expectEqual(@as(usize, 1), stats.carriage_return_count);

    const empty = TextStats.of("");
    try std.testing.expectEqual(@as(usize, 0), empty.byte_count);
    try std.testing.expectEqual(@as(usize, 0), empty.carriage_return_count);
}
