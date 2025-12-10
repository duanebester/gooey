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

// Update state struct to add scroll demo data
var state = struct {
    const Self = @This();
    const Page = enum { home, forms, about, scroll_demo };
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

    // Checkbox state
    agree_terms: bool = false,
    subscribe_newsletter: bool = false,
    enable_notifications: bool = true,

    // Stats (for home page)
    click_count: u32 = 0,

    pub fn toggleTheme(self: *Self) void {
        self.is_dark = !self.is_dark;
        self.theme = if (self.is_dark) &Theme.dark else &Theme.light;
    }

    pub fn nextPage(self: *Self) void {
        self.page = switch (self.page) {
            .home => .forms,
            .forms => .scroll_demo,
            .scroll_demo => .about,
            .about => .home,
        };
    }

    pub fn prevPage(self: *Self) void {
        self.page = switch (self.page) {
            .home => .about,
            .forms => .home,
            .scroll_demo => .forms,
            .about => .scroll_demo,
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
        .width = 800,
        .height = 600,
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
            NavTab{ .label = "Scroll", .page = .scroll_demo, .key = "3" },
            NavTab{ .label = "About", .page = .about, .key = "4" },
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
            .fill_width = true,
            .fill_height = true,
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

/// Scroll Demo page
const ScrollDemoPage = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .all = 32 },
            .gap = 24,
            .fill_width = true,
            .fill_height = true,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("Scroll Container Demo", .{ .size = 24, .color = t.text }),
            ui.text("Scroll with mousewheel or trackpad", .{ .size = 14, .color = t.muted }),

            b.box(.{
                .direction = .row,
                .gap = 24,
                .alignment = .{ .main = .center },
            }, .{
                ScrollableList{},
                ScrollableCards{},
            }),
        });
    }
};

const ScrollableList = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .gap = 8,
            .alignment = .{ .cross = .start },
        }, .{
            ui.text("Item List", .{ .size = 14, .color = t.muted }),

            b.scroll("list_scroll", .{
                .width = 200,
                .height = 250,
                .background = t.card,
                .corner_radius = 8,
                .padding = .{ .all = 8 },
                .gap = 6,
                .content_height = 500, // Content is taller than viewport
                .track_color = t.bg,
                .thumb_color = t.muted,
            }, .{
                // Generate list items
                ListItem{ .index = 1 },
                ListItem{ .index = 2 },
                ListItem{ .index = 3 },
                ListItem{ .index = 4 },
                ListItem{ .index = 5 },
                ListItem{ .index = 6 },
                ListItem{ .index = 7 },
                ListItem{ .index = 8 },
                ListItem{ .index = 9 },
                ListItem{ .index = 10 },
                ListItem{ .index = 11 },
                ListItem{ .index = 12 },
                ListItem{ .index = 13 },
                ListItem{ .index = 14 },
                ListItem{ .index = 15 },
            }),
        });
    }
};

const ListItem = struct {
    index: u32,

    var buf: [32]u8 = undefined;

    pub fn render(self: @This(), b: *ui.Builder) void {
        const t = state.theme;
        const label = std.fmt.bufPrint(&buf, "List Item {d}", .{self.index}) catch "Item";

        b.box(.{
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = t.bg,
            .corner_radius = 4,
            .fill_width = true,
        }, .{
            ui.text(label, .{ .size = 13, .color = t.text }),
        });
    }
};

const ScrollableCards = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .gap = 8,
            .alignment = .{ .cross = .start },
        }, .{
            ui.text("Card Stack", .{ .size = 14, .color = t.muted }),

            b.scroll("cards_scroll", .{
                .width = 220,
                .height = 250,
                .background = t.bg,
                .corner_radius = 8,
                .padding = .{ .all = 12 },
                .gap = 12,
                .content_height = 600,
                .track_color = t.card,
                .thumb_color = t.primary,
            }, .{
                InfoCard{ .title = "Performance", .desc = "GPU-accelerated rendering" },
                InfoCard{ .title = "Layout", .desc = "Flexbox-style system" },
                InfoCard{ .title = "Text", .desc = "CoreText shaping" },
                InfoCard{ .title = "Widgets", .desc = "Retained state" },
                InfoCard{ .title = "Clipping", .desc = "Nested scroll areas" },
                InfoCard{ .title = "Themes", .desc = "Dark mode support" },
            }),
        });
    }
};

const InfoCard = struct {
    title: []const u8,
    desc: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .all = 12 },
            .gap = 4,
            .background = t.card,
            .corner_radius = 6,
            .fill_width = true,
        }, .{
            ui.text(self.title, .{ .size = 14, .color = t.primary }),
            ui.text(self.desc, .{ .size = 12, .color = t.muted }),
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
            .fill_width = true,
            .fill_height = true,
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

const CheckboxSection = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const t = state.theme;

        b.box(.{
            .padding = .{ .all = 20 },
            .gap = 14,
            .background = t.card,
            .corner_radius = 8,
            .direction = .column,
            .alignment = .{ .cross = .start },
        }, .{
            ui.text("Preferences", .{ .size = 14, .color = t.muted }),

            ui.checkbox("agree_terms", .{
                .label = "I agree to the terms and conditions",
                .bind = &state.agree_terms,
                // Theme colors
                .background = t.card,
                .background_checked = t.primary,
                .border_color = t.muted,
                .checkmark_color = ui.Color.white,
                .label_color = t.text,
            }),

            ui.checkbox("subscribe", .{
                .label = "Subscribe to newsletter",
                .bind = &state.subscribe_newsletter,
                .background = t.card,
                .background_checked = t.primary,
                .border_color = t.muted,
                .checkmark_color = ui.Color.white,
                .label_color = t.text,
            }),

            ui.checkbox("notifications", .{
                .label = "Enable notifications",
                .bind = &state.enable_notifications,
                .background = t.card,
                .background_checked = t.accent, // Use accent for variety
                .border_color = t.muted,
                .checkmark_color = ui.Color.white,
                .label_color = t.text,
            }),
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
            CheckboxSection{},
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
            .fill_width = true,
            .fill_height = true,
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
            .alignment = .{ .cross = .start },
        }, .{
            FeatureItem{ .text = "Metal GPU rendering" },
            FeatureItem{ .text = "Immediate-mode layout" },
            FeatureItem{ .text = "Retained text input widgets" },
            FeatureItem{ .text = "Checkbox components" },
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
        if (state.page == .scroll_demo) {
            b.box(.{ .grow = true }, .{ScrollDemoPage{}});
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
                state.goTo(.scroll_demo);
                return true;
            }
            if (key.key == .@"4") {
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
