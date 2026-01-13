//! Lucide Icons Demo
//!
//! Demonstrates Lucide icons rendering with SVG shape elements (circle, rect, line, polyline).
//! These icons use stroke-based design and are automatically converted to path commands.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    frame: u32 = 0,
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Lucide Icons Demo",
    .width = 700,
    .height = 650,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Icon Card Component
// =============================================================================

const IconCard = struct {
    path: []const u8,
    label: []const u8,

    pub fn render(self: IconCard, b: *ui.Builder) void {
        b.box(.{
            .width = 70,
            .height = 70,
            .padding = .{ .all = 6 },
            .gap = 4,
            .direction = .column,
            .alignment = .{ .main = .center, .cross = .center },
            .corner_radius = 8,
            .background = ui.Color.hex(0x1e293b),
        }, .{
            Svg{
                .path = self.path,
                .size = 24,
                .no_fill = true,
                .stroke_color = ui.Color.hex(0xe2e8f0),
                .stroke_width = 2,
            },
            ui.text(self.label, .{
                .size = 9,
                .color = ui.Color.hex(0x64748b),
            }),
        });
    }
};

// =============================================================================
// Section Header Component
// =============================================================================

const SectionHeader = struct {
    title: []const u8,

    pub fn render(self: SectionHeader, b: *ui.Builder) void {
        b.box(.{
            .padding = .{ .all = 4 },
        }, .{
            ui.text(self.title, .{
                .size = 14,
                .color = ui.Color.hex(0x60a5fa),
                .weight = .semibold,
            }),
        });
    }
};

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 24 },
        .gap = 16,
        .direction = .column,
        .background = ui.Color.hex(0x0f172a),
    }, .{
        // Header
        ui.text("Lucide Icons Demo", .{
            .size = 28,
            .color = ui.Color.white,
            .weight = .bold,
        }),
        ui.text("Stroke-based icons using SVG shape elements (circle, rect, line, polyline)", .{
            .size = 13,
            .color = ui.Color.hex(0x94a3b8),
        }),

        // Navigation Section
        SectionHeader{ .title = "Navigation" },
        ui.box(.{ .gap = 8, .direction = .row }, .{
            IconCard{ .path = Lucide.arrow_left, .label = "arrow_left" },
            IconCard{ .path = Lucide.arrow_right, .label = "arrow_right" },
            IconCard{ .path = Lucide.arrow_up, .label = "arrow_up" },
            IconCard{ .path = Lucide.arrow_down, .label = "arrow_down" },
            IconCard{ .path = Lucide.chevron_left, .label = "chevron_left" },
            IconCard{ .path = Lucide.chevron_right, .label = "chevron_right" },
            IconCard{ .path = Lucide.menu, .label = "menu" },
            IconCard{ .path = Lucide.x, .label = "x" },
        }),

        // Actions Section
        SectionHeader{ .title = "Actions" },
        ui.box(.{ .gap = 8, .direction = .row }, .{
            IconCard{ .path = Lucide.check, .label = "check" },
            IconCard{ .path = Lucide.plus, .label = "plus" },
            IconCard{ .path = Lucide.minus, .label = "minus" },
            IconCard{ .path = Lucide.search, .label = "search" },
            IconCard{ .path = Lucide.pencil, .label = "pencil" },
            IconCard{ .path = Lucide.trash, .label = "trash" },
            IconCard{ .path = Lucide.copy, .label = "copy" },
            IconCard{ .path = Lucide.settings, .label = "settings" },
        }),

        // Status Section
        SectionHeader{ .title = "Status & Feedback" },
        ui.box(.{ .gap = 8, .direction = .row }, .{
            IconCard{ .path = Lucide.check_circle, .label = "check_circle" },
            IconCard{ .path = Lucide.alert_circle, .label = "alert_circle" },
            IconCard{ .path = Lucide.alert_triangle, .label = "alert_tri" },
            IconCard{ .path = Lucide.info, .label = "info" },
            IconCard{ .path = Lucide.x_circle, .label = "x_circle" },
            IconCard{ .path = Lucide.bell, .label = "bell" },
            IconCard{ .path = Lucide.eye, .label = "eye" },
            IconCard{ .path = Lucide.lock, .label = "lock" },
        }),

        // Media Section
        SectionHeader{ .title = "Media & Communication" },
        ui.box(.{ .gap = 8, .direction = .row }, .{
            IconCard{ .path = Lucide.play, .label = "play" },
            IconCard{ .path = Lucide.pause, .label = "pause" },
            IconCard{ .path = Lucide.skip_forward, .label = "skip_fwd" },
            IconCard{ .path = Lucide.skip_back, .label = "skip_back" },
            IconCard{ .path = Lucide.mail, .label = "mail" },
            IconCard{ .path = Lucide.send, .label = "send" },
            IconCard{ .path = Lucide.user, .label = "user" },
            IconCard{ .path = Lucide.users, .label = "users" },
        }),

        // Files Section
        SectionHeader{ .title = "Files & UI" },
        ui.box(.{ .gap = 8, .direction = .row }, .{
            IconCard{ .path = Lucide.file, .label = "file" },
            IconCard{ .path = Lucide.folder, .label = "folder" },
            IconCard{ .path = Lucide.download, .label = "download" },
            IconCard{ .path = Lucide.upload, .label = "upload" },
            IconCard{ .path = Lucide.home, .label = "home" },
            IconCard{ .path = Lucide.star, .label = "star" },
            IconCard{ .path = Lucide.heart, .label = "heart" },
            IconCard{ .path = Lucide.calendar, .label = "calendar" },
        }),

        // Dev Section
        SectionHeader{ .title = "Development" },
        ui.box(.{ .gap = 8, .direction = .row }, .{
            IconCard{ .path = Lucide.code, .label = "code" },
            IconCard{ .path = Lucide.terminal, .label = "terminal" },
            IconCard{ .path = Lucide.github, .label = "github" },
            IconCard{ .path = Lucide.link, .label = "link" },
            IconCard{ .path = Lucide.external_link, .label = "ext_link" },
            IconCard{ .path = Lucide.zap, .label = "zap" },
            IconCard{ .path = Lucide.grid, .label = "grid" },
            IconCard{ .path = Lucide.clock, .label = "clock" },
        }),
    }));
}

// =============================================================================
// Tests
// =============================================================================

test "AppState" {
    const s = AppState{};
    try std.testing.expectEqual(@as(u32, 0), s.frame);
}
