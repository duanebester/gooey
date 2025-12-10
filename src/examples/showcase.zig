//! Gooey Showcase
//!
//! A feature-rich demo showing off gooey's capabilities:
//! - Tab navigation between pages
//! - Form inputs with validation
//! - Component composition
//! - Keyboard shortcuts
//! - Theming

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const ShadowConfig = ui.ShadowConfig;

// =============================================================================
// Theme
// =============================================================================

const Theme = struct {
    bg: ui.Color,
    card: ui.Color,
    primary: ui.Color,
    text: ui.Color,
    muted: ui.Color,
    accent: ui.Color,

    const light = Theme{
        .bg = ui.Color.rgb(0.95, 0.95, 0.95),
        .card = ui.Color.white,
        .primary = ui.Color.rgb(0.2, 0.5, 1.0),
        .text = ui.Color.rgb(0.1, 0.1, 0.1),
        .muted = ui.Color.rgb(0.5, 0.5, 0.5),
        .accent = ui.Color.rgb(0.3, 0.7, 0.4),
    };

    const dark = Theme{
        .bg = ui.Color.rgb(0.12, 0.12, 0.14),
        .card = ui.Color.rgb(0.18, 0.18, 0.20),
        .primary = ui.Color.rgb(0.4, 0.6, 1.0),
        .text = ui.Color.rgb(0.9, 0.9, 0.9),
        .muted = ui.Color.rgb(0.6, 0.6, 0.6),
        .accent = ui.Color.rgb(0.4, 0.8, 0.5),
    };
};

// =============================================================================
// Application State
// =============================================================================

var state = struct {
    const Self = @This();
    const Page = enum { home, forms, about };
    const FormField = enum { name, email, message };

    // Navigation
    page: Page = .home,
    theme: *const Theme = &Theme.light,
    is_dark: bool = false,

    // Form state
    name: []const u8 = "",
    email: []const u8 = "",
    message: []const u8 = "",
    form_status: []const u8 = "",
    focused_field: FormField = .name,
    form_initialized: bool = false,

    // Stats (for home page)
    click_count: u32 = 0,

    pub fn toggleTheme(self: *Self) void {
        self.is_dark = !self.is_dark;
        self.theme = if (self.is_dark) &Theme.dark else &Theme.light;
    }

    pub fn nextPage(self: *Self) void {
        self.page = switch (self.page) {
            .home => .forms,
            .forms => .about,
            .about => .home,
        };
    }

    pub fn prevPage(self: *Self) void {
        self.page = switch (self.page) {
            .home => .about,
            .forms => .home,
            .about => .forms,
        };
    }

    pub fn goTo(self: *Self, page: Page) void {
        self.page = page;
        if (page == .forms) {
            self.form_initialized = false;
        }
    }

    pub fn focusNextField(self: *Self) void {
        self.focused_field = switch (self.focused_field) {
            .name => .email,
            .email => .message,
            .message => .name,
        };
    }

    pub fn submitForm(self: *Self) void {
        if (self.name.len == 0) {
            self.form_status = "Please enter your name";
        } else if (self.email.len == 0) {
            self.form_status = "Please enter your email";
        } else if (std.mem.indexOf(u8, self.email, "@") == null) {
            self.form_status = "Please enter a valid email";
        } else {
            self.form_status = "Form submitted successfully!";
        }
    }
}{};

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() !void {
    try gooey.run(.{
        .title = "Gooey Showcase",
        .width = 600,
        .height = 500,
        .render = render,
        .on_event = onEvent,
    });
}

// =============================================================================
// Components
// =============================================================================

const ThemeToggle = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .symmetric = .{ .x = 0, .y = 8 } },
        }, .{
            ui.text("[T] Theme", .{ .size = 12, .color = t.muted }),
        });
    }
};

/// Navigation bar with tabs
const NavBar = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .direction = .row,
            .padding = .{ .symmetric = .{ .x = 16, .y = 8 } },
            .gap = 8,
            .background = t.card,
            .fill_width = true,
            .alignment = .{ .cross = .center },
        }, .{
            NavTab{ .label = "Home", .page = .home, .key = "1" },
            NavTab{ .label = "Forms", .page = .forms, .key = "2" },
            NavTab{ .label = "About", .page = .about, .key = "3" },
            ui.spacer(),
            ThemeToggle{},
        });
    }
};

const NavTab = struct {
    label: []const u8,
    page: @TypeOf(state).Page,
    key: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        const t = state.theme;
        const is_active = state.page == self.page;

        b.box(.{
            .padding = .{ .symmetric = .{ .x = 16, .y = 8 } },
            .corner_radius = 6,
            .background = if (is_active) t.primary else ui.Color.transparent,
        }, .{
            ui.textFmt("[{s}] {s}", .{ self.key, self.label }, .{
                .size = 14,
                .color = if (is_active) ui.Color.white else t.text,
            }),
        });
    }
};

/// Home page content
const HomePage = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .all = 32 },
            .gap = 24,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("Welcome to Gooey", .{ .size = 32, .color = t.text }),
            ui.text("A GPU-accelerated UI framework for Zig", .{ .size = 16, .color = t.muted }),
            StatsRow{},
            ButtonRow{},
            ui.text("Use arrow keys or [1-3] to navigate", .{ .size = 12, .color = t.muted }),
        });
    }
};

const StatsRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 24 },
            .background = t.card,
            .shadow = ShadowConfig.drop(6),
            .corner_radius = 12,
        }, .{
            StatCard{ .label = "Clicks", .value = state.click_count },
            StatCard{ .label = "Page", .value = @intFromEnum(state.page) + 1 },
        });
    }
};

const ButtonRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{ .direction = .row, .gap = 12 }, .{
            ui.button("Click Me!", increment),
            ui.button("Reset", reset),
        });
    }

    fn increment() void {
        state.click_count += 1;
    }

    fn reset() void {
        state.click_count = 0;
    }
};

const StatCard = struct {
    label: []const u8,
    value: u32,

    var buf: [16]u8 = undefined;

    pub fn render(self: @This(), b: *ui.Builder) void {
        const t = state.theme;
        const value_str = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch "?";

        b.box(.{
            .padding = .{ .all = 16 },
            .gap = 4,
            .alignment = .{ .main = .center, .cross = .center },
            .background = t.bg,
            .corner_radius = 8,
            .min_width = 80,
        }, .{
            ui.text(value_str, .{ .size = 28, .color = t.primary }),
            ui.text(self.label, .{ .size = 12, .color = t.muted }),
        });
    }
};

/// Forms page content
const FormsPage = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .all = 32 },
            .gap = 16,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("Contact Form", .{ .size = 24, .color = t.text }),
            ui.text(if (state.form_status.len > 0) state.form_status else "Fill out the form below", .{
                .size = 14,
                .color = if (std.mem.indexOf(u8, state.form_status, "success") != null) t.accent else t.muted,
            }),
            FormCard{},
            ui.text("[Tab] to move between fields", .{ .size = 12, .color = t.muted }),
        });
    }
};

const FormCard = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .shadow = ShadowConfig.drop(6),
            .padding = .{ .all = 24 },
            .gap = 12,
            .background = t.card,
            .corner_radius = 12,
        }, .{
            ui.input("form_name", .{
                .placeholder = "Your Name",
                .width = 280,
                .bind = &state.name,
            }),
            ui.input("form_email", .{
                .placeholder = "Email Address",
                .width = 280,
                .bind = &state.email,
            }),
            ui.input("form_message", .{
                .placeholder = "Message",
                .width = 280,
                .bind = &state.message,
            }),
            ui.button("Submit", submitForm),
        });
    }

    fn submitForm() void {
        state.submitForm();
    }
};

/// About page content
const AboutPage = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .all = 32 },
            .gap = 16,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("About Gooey", .{ .size = 24, .color = t.text }),
            FeatureCard{},
            ui.text("Built with Zig + Metal", .{ .size = 14, .color = t.muted }),
        });
    }
};

const FeatureCard = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .all = 24 },
            .gap = 12,
            .shadow = ShadowConfig.drop(6),
            .background = t.card,
            .corner_radius = 12,
            .alignment = .{ .cross = .center },
        }, .{
            FeatureItem{ .text = "Metal GPU rendering" },
            FeatureItem{ .text = "Immediate-mode layout" },
            FeatureItem{ .text = "Retained text input widgets" },
            FeatureItem{ .text = "CoreText font shaping" },
            FeatureItem{ .text = "Simple component model" },
        });
    }
};

const FeatureItem = struct {
    text: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .direction = .row,
            .gap = 12,
            .alignment = .{ .cross = .center },
        }, .{
            ui.text("*", .{ .size = 14, .color = t.accent }),
            ui.text(self.text, .{ .size = 14, .color = t.text }),
        });
    }
};

// =============================================================================
// Render
// =============================================================================

fn render(g: *gooey.UI) void {
    const size = g.windowSize();
    const t = state.theme;

    // Initialize form focus on first render of forms page
    if (state.page == .forms and !state.form_initialized) {
        state.form_initialized = true;
        syncFormFocus(g);
    } else if (state.page != .forms) {
        // Blur text inputs when not on forms page
        g.gooey.widgets.blurAll();
    }

    g.box(.{
        .width = size.width,
        .height = size.height,
        .background = t.bg,
        .direction = .column,
    }, .{
        NavBar{},
        PageContent{},
    });
}

const PageContent = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        if (state.page == .home) {
            b.box(.{ .grow = true }, .{HomePage{}});
        }
        if (state.page == .forms) {
            b.box(.{ .grow = true }, .{FormsPage{}});
        }
        if (state.page == .about) {
            b.box(.{ .grow = true }, .{AboutPage{}});
        }
    }
};

fn syncFormFocus(g: *gooey.UI) void {
    switch (state.focused_field) {
        .name => g.focusTextInput("form_name"),
        .email => g.focusTextInput("form_email"),
        .message => g.focusTextInput("form_message"),
    }
}

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(g: *gooey.UI, event: gooey.InputEvent) bool {
    if (event == .key_down) {
        const key = event.key_down;

        // DEBUG: print what key we received
        std.debug.print("Key pressed: {}\n", .{key.key});

        // Tab navigation (forms page)
        if (key.key == .tab and state.page == .forms) {
            state.focusNextField();
            syncFormFocus(g);
            return true;
        }

        const no_mods = !key.modifiers.shift and !key.modifiers.cmd and
            !key.modifiers.alt and !key.modifiers.ctrl;

        // Number keys for page navigation (only without modifiers)
        if (no_mods) {
            if (key.key == .@"1") {
                state.goTo(.home);
                return true;
            }
            if (key.key == .@"2") {
                state.goTo(.forms);
                return true;
            }
            if (key.key == .@"3") {
                state.goTo(.about);
                return true;
            }
        }

        // Arrow keys
        if (key.key == .left) {
            state.prevPage();
            return true;
        }
        if (key.key == .right) {
            state.nextPage();
            return true;
        }

        // Theme toggle
        if (key.key == .t and state.page != .forms) {
            state.toggleTheme();
            return true;
        }

        // Enter to submit form
        if (key.key == .@"return" and state.page == .forms) {
            state.submitForm();
            return true;
        }
    }

    return false;
}
