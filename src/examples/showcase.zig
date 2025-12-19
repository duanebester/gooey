//! Gooey Showcase (Cx API)
//!
//! A comprehensive demo showing gooey's capabilities:
//! - Component pattern (Button, Checkbox, TextInput)
//! - Pure state pattern with cx.update() / cx.updateWith()
//! - Tab navigation between pages
//! - Form inputs with validation
//! - Text styles (underline, strikethrough, wrap modes)
//! - Layout features (shrink, grow, aspect ratio)
//! - Scroll containers
//! - Theming
//! - Keyboard shortcuts

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const Cx = gooey.Cx;

const ShadowConfig = ui.ShadowConfig;
const Gooey = gooey.Gooey;
const Button = gooey.Button;
const Checkbox = gooey.Checkbox;
const TextInput = gooey.TextInput;
const TextArea = gooey.TextArea;

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
    danger: ui.Color,

    // Catppuccin Latte (light theme)
    const light = Theme{
        .bg = ui.Color.rgb(0.937, 0.945, 0.961),
        .card = ui.Color.rgb(0.902, 0.914, 0.933),
        .primary = ui.Color.rgb(0.118, 0.400, 0.961),
        .text = ui.Color.rgb(0.298, 0.310, 0.412),
        .muted = ui.Color.rgb(0.424, 0.435, 0.522),
        .accent = ui.Color.rgb(0.251, 0.627, 0.169),
        .danger = ui.Color.rgb(0.82, 0.24, 0.24),
    };

    // Catppuccin Macchiato (dark theme)
    const dark = Theme{
        .bg = ui.Color.rgb(0.141, 0.153, 0.227),
        .card = ui.Color.rgb(0.212, 0.227, 0.310),
        .primary = ui.Color.rgb(0.541, 0.678, 0.957),
        .text = ui.Color.rgb(0.792, 0.827, 0.961),
        .muted = ui.Color.rgb(0.647, 0.678, 0.796),
        .accent = ui.Color.rgb(0.651, 0.855, 0.584),
        .danger = ui.Color.rgb(0.93, 0.49, 0.49),
    };
};

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    const Page = enum { home, forms, scroll_demo, about };
    const FormField = enum { name, email, message };

    // Navigation
    page: Page = .home,
    theme: *const Theme = &Theme.light,
    is_dark: bool = false,

    // Form state
    name: []const u8 = "",
    email: []const u8 = "",
    message: []const u8 = "",
    bio: []const u8 = "",
    form_status: []const u8 = "",
    focused_field: FormField = .name,
    form_initialized: bool = false,

    // Checkbox state
    agree_terms: bool = false,
    subscribe_newsletter: bool = false,
    enable_notifications: bool = true,

    // Stats (for home page)
    click_count: u32 = 0,

    // Layout demo state
    completed_tasks: [3]bool = .{ false, true, false },

    // =========================================================================
    // PURE methods - fn(*State) or fn(*State, Arg)
    // Use with cx.update() / cx.updateWith()
    // Fully testable without framework!
    // =========================================================================

    pub fn toggleTheme(self: *AppState) void {
        self.is_dark = !self.is_dark;
        self.theme = if (self.is_dark) &Theme.dark else &Theme.light;
    }

    pub fn nextPage(self: *AppState) void {
        self.page = switch (self.page) {
            .home => .forms,
            .forms => .scroll_demo,
            .scroll_demo => .about,
            .about => .home,
        };
    }

    pub fn prevPage(self: *AppState) void {
        self.page = switch (self.page) {
            .home => .about,
            .forms => .home,
            .scroll_demo => .forms,
            .about => .scroll_demo,
        };
    }

    pub fn goToPage(self: *AppState, page: Page) void {
        self.page = page;
        if (page == .forms) {
            self.form_initialized = false;
        }
    }

    pub fn increment(self: *AppState) void {
        self.click_count +|= 1;
    }

    pub fn resetClicks(self: *AppState) void {
        self.click_count = 0;
    }

    pub fn toggleAgreeTerms(self: *AppState) void {
        self.agree_terms = !self.agree_terms;
    }

    pub fn toggleSubscribe(self: *AppState) void {
        self.subscribe_newsletter = !self.subscribe_newsletter;
    }

    pub fn toggleNotifications(self: *AppState) void {
        self.enable_notifications = !self.enable_notifications;
    }

    pub fn toggleTask(self: *AppState, index: usize) void {
        if (index < self.completed_tasks.len) {
            self.completed_tasks[index] = !self.completed_tasks[index];
        }
    }

    pub fn focusNextField(self: *AppState) void {
        self.focused_field = switch (self.focused_field) {
            .name => .email,
            .email => .message,
            .message => .name,
        };
    }

    pub fn submitForm(self: *AppState) void {
        if (self.name.len == 0) {
            self.form_status = "Please enter your name";
        } else if (self.email.len == 0) {
            self.form_status = "Please enter your email";
        } else if (!self.agree_terms) {
            self.form_status = "Please agree to terms";
        } else {
            self.form_status = "Form submitted successfully!";
        }
    }

    // =========================================================================
    // Command methods - fn(*State, *Gooey) or fn(*State, *Gooey, Arg)
    // Use with cx.command() / cx.commandWith()
    // =========================================================================

    pub fn goToFormsWithFocus(self: *AppState, g: *Gooey) void {
        self.page = .forms;
        self.form_initialized = true;
        self.focused_field = .name;
        g.focusTextInput("form_name");
    }

    pub fn focusField(self: *AppState, g: *Gooey) void {
        switch (self.focused_field) {
            .name => g.focusTextInput("form_name"),
            .email => g.focusTextInput("form_email"),
            .message => g.focusTextInput("form_message"),
        }
    }

    pub fn submitFormAndBlur(self: *AppState, g: *Gooey) void {
        self.submitForm();
        if (std.mem.indexOf(u8, self.form_status, "success") != null) {
            g.blurAll();
        }
    }
};

// =============================================================================
// Entry Point
// =============================================================================

var app_state = AppState{};

const App = gooey.App(AppState, &app_state, render, .{
    .title = "Gooey Showcase",
    .width = 900,
    .height = 650,
    .on_event = onEvent,
});

comptime {
    _ = App;
}

const platform = gooey.platform;
pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Components - Now receive *Cx directly!
// =============================================================================

const ThemeToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .padding = .{ .symmetric = .{ .x = 0, .y = 8 } },
        }, .{
            ui.text("[T] Theme", .{ .size = 12, .color = t.muted }),
        });
    }
};

/// Navigation bar with tabs
const NavBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
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
    page: AppState.Page,
    key: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = s.theme;
        const is_active = s.page == self.page;

        cx.box(.{
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

// =============================================================================
// Home Page
// =============================================================================

const HomePage = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
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
            ui.text("Use arrow keys or [1-4] to navigate", .{ .size = 12, .color = t.muted }),
        });
    }
};

const StatsRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = s.theme;

        cx.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 24 },
            .background = t.card,
            .shadow = ShadowConfig.drop(6),
            .corner_radius = 12,
        }, .{
            StatCard{ .label = "Clicks", .value = s.click_count },
            StatCard{ .label = "Page", .value = @intFromEnum(s.page) + 1 },
        });
    }
};

const ButtonRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .direction = .row, .gap = 12 }, .{
            Button{ .label = "Click Me!", .on_click_handler = cx.update(AppState, AppState.increment) },
            Button{ .label = "Reset", .variant = .secondary, .on_click_handler = cx.update(AppState, AppState.resetClicks) },
        });
    }
};

const StatCard = struct {
    label: []const u8,
    value: u32,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .padding = .{ .all = 16 },
            .gap = 4,
            .alignment = .{ .main = .center, .cross = .center },
            .background = t.bg,
            .corner_radius = 8,
            .min_width = 80,
        }, .{
            ui.textFmt("{d}", .{self.value}, .{ .size = 28, .color = t.primary }),
            ui.text(self.label, .{ .size = 12, .color = t.muted }),
        });
    }
};

// =============================================================================
// Forms Page
// =============================================================================

const FormsPage = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = s.theme;

        cx.box(.{
            .padding = .{ .all = 32 },
            .gap = 16,
            .fill_width = true,
            .fill_height = true,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("Contact Form", .{ .size = 24, .color = t.text }),
            ui.text(if (s.form_status.len > 0) s.form_status else "Fill out the form below", .{
                .size = 14,
                .color = if (std.mem.indexOf(u8, s.form_status, "success") != null) t.accent else t.muted,
            }),
            FormCard{},
            ui.text("[Tab] to move between fields", .{ .size = 12, .color = t.muted }),
        });
    }
};

const CheckboxSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = s.theme;

        cx.box(.{
            .padding = .{ .all = 20 },
            .gap = 14,
            .background = t.card,
            .corner_radius = 8,
            .direction = .column,
            .alignment = .{ .cross = .start },
        }, .{
            ui.text("Preferences", .{ .size = 14, .color = t.muted }),

            Checkbox{
                .id = "agree_terms",
                .checked = s.agree_terms,
                .label = "I agree to the terms and conditions",
                .on_click_handler = cx.update(AppState, AppState.toggleAgreeTerms),
                .unchecked_background = t.bg,
                .checked_background = t.primary,
                .border_color = t.muted,
                .checkmark_color = ui.Color.white,
                .label_color = t.text,
            },

            Checkbox{
                .id = "subscribe",
                .checked = s.subscribe_newsletter,
                .label = "Subscribe to newsletter",
                .on_click_handler = cx.update(AppState, AppState.toggleSubscribe),
                .unchecked_background = t.bg,
                .checked_background = t.primary,
                .border_color = t.muted,
                .checkmark_color = ui.Color.white,
                .label_color = t.text,
            },

            Checkbox{
                .id = "notifications",
                .checked = s.enable_notifications,
                .label = "Enable notifications",
                .on_click_handler = cx.update(AppState, AppState.toggleNotifications),
                .unchecked_background = t.bg,
                .checked_background = t.accent,
                .border_color = t.muted,
                .checkmark_color = ui.Color.white,
                .label_color = t.text,
            },
        });
    }
};

const FormCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = s.theme;

        cx.box(.{
            .shadow = ShadowConfig.drop(6),
            .padding = .{ .all = 24 },
            .gap = 12,
            .background = t.card,
            .corner_radius = 12,
        }, .{
            TextInput{
                .id = "form_name",
                .placeholder = "Your Name",
                .width = 280,
                .bind = &s.name,
                // Theme-aware styling
                .background = t.bg,
                .border_color = t.muted.withAlpha(0.3),
                .border_color_focused = t.primary,
                .text_color = t.text,
                .placeholder_color = t.muted,
                .corner_radius = 8,
            },
            TextInput{
                .id = "form_email",
                .placeholder = "Email Address",
                .width = 280,
                .bind = &s.email,
                .background = t.bg,
                .border_color = t.muted.withAlpha(0.3),
                .border_color_focused = t.primary,
                .text_color = t.text,
                .placeholder_color = t.muted,
                .corner_radius = 8,
            },
            TextInput{
                .id = "form_message",
                .placeholder = "Message",
                .width = 280,
                .bind = &s.message,
                .background = t.bg,
                .border_color = t.muted.withAlpha(0.3),
                .border_color_focused = t.primary,
                .text_color = t.text,
                .placeholder_color = t.muted,
                .corner_radius = 8,
            },
            TextArea{
                .id = "form_bio",
                .placeholder = "Tell us about yourself...",
                .width = 280,
                .height = 120,
                .bind = &s.bio,
                .background = t.bg,
                .border_color = t.muted.withAlpha(0.3),
                .border_color_focused = t.primary,
                .text_color = t.text,
                .placeholder_color = t.muted,
                .corner_radius = 8,
            },
            CheckboxSection{},
            Button{ .label = "Submit", .on_click_handler = cx.command(AppState, AppState.submitFormAndBlur) },
        });
    }
};

// =============================================================================
// Scroll Demo Page
// =============================================================================

const ScrollDemoPage = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .direction = .column,
            .fill_width = true,
            .grow = true,
        }, .{
            cx.box(.{
                .direction = .row,
                .padding = .{ .symmetric = .{ .x = 24, .y = 16 } },
                .gap = 16,
                .background = t.card,
                .fill_width = true,
                .alignment = .{ .cross = .center },
            }, .{
                ui.text("Scroll Container Demo", .{ .size = 20, .color = t.text }),
                ui.text("Scroll with mousewheel or trackpad", .{ .size = 14, .color = t.muted }),
            }),

            cx.box(.{
                .direction = .row,
                .gap = 24,
                .padding = .{ .all = 32 },
                .grow = true,
                .fill_width = true,
                .alignment = .{ .main = .center, .cross = .start },
            }, .{
                ScrollableList{},
                ScrollableCards{},
            }),
        });
    }
};

const ScrollableList = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .gap = 8,
            .alignment = .{ .cross = .start },
        }, .{
            ui.text("Item List", .{ .size = 14, .color = t.muted }),

            cx.scroll("list_scroll", .{
                .width = 200,
                .height = 250,
                .background = t.card,
                .corner_radius = 8,
                .padding = .{ .all = 8 },
                .gap = 6,
                .content_height = 500,
                .track_color = t.bg,
                .thumb_color = t.muted,
            }, .{
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

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = t.bg,
            .corner_radius = 4,
            .fill_width = true,
        }, .{
            ui.textFmt("List Item {d}", .{self.index}, .{ .size = 13, .color = t.text }),
        });
    }
};

const ScrollableCards = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .gap = 8,
            .alignment = .{ .cross = .start },
        }, .{
            ui.text("Card Stack", .{ .size = 14, .color = t.muted }),

            cx.scroll("cards_scroll", .{
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

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
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

// =============================================================================
// About Page
// =============================================================================

const AboutPage = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
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
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .padding = .{ .all = 24 },
            .gap = 12,
            .shadow = ShadowConfig.drop(6),
            .background = t.card,
            .corner_radius = 12,
            .alignment = .{ .cross = .start },
        }, .{
            FeatureItem{ .text = "Metal GPU rendering" },
            FeatureItem{ .text = "Pure state pattern" },
            FeatureItem{ .text = "Component system (Button, Checkbox, TextInput)" },
            FeatureItem{ .text = "Text styles (underline, strikethrough)" },
            FeatureItem{ .text = "CoreText font shaping" },
            FeatureItem{ .text = "Scroll containers" },
        });
    }
};

const FeatureItem = struct {
    text: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.state(AppState).theme;

        cx.box(.{
            .direction = .row,
            .gap = 12,
            .alignment = .{ .cross = .center },
        }, .{
            ui.text("✓", .{ .size = 14, .color = t.accent }),
            ui.text(self.text, .{ .size = 14, .color = t.text }),
        });
    }
};

// =============================================================================
// Render & Events
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const t = s.theme;
    const size = cx.windowSize();
    const g = cx.getGooey();

    // Initialize form focus on first render of forms page
    if (s.page == .forms and !s.form_initialized) {
        s.form_initialized = true;
        syncFormFocus(s, g);
    } else if (s.page != .forms) {
        g.blurAll();
    }

    cx.box(.{
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
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        switch (s.page) {
            .home => cx.box(.{ .grow = true }, .{HomePage{}}),
            .forms => cx.box(.{ .grow = true }, .{FormsPage{}}),
            .scroll_demo => cx.box(.{ .grow = true }, .{ScrollDemoPage{}}),
            .about => cx.box(.{ .grow = true }, .{AboutPage{}}),
        }
    }
};

fn syncFormFocus(s: *AppState, g: *Gooey) void {
    switch (s.focused_field) {
        .name => g.focusTextInput("form_name"),
        .email => g.focusTextInput("form_email"),
        .message => g.focusTextInput("form_message"),
    }
}

fn onEvent(cx: *Cx, event: gooey.InputEvent) bool {
    const s = cx.state(AppState);
    const g = cx.getGooey();

    // Let focused text widgets handle their own input
    if (g.getFocusedTextArea() != null) {
        return false; // Let framework handle it
    }

    if (event == .key_down) {
        const key = event.key_down;

        // Tab navigation (forms page)
        if (key.key == .tab and s.page == .forms) {
            s.focusNextField();
            syncFormFocus(s, g);
            cx.notify();
            return true;
        }

        const no_mods = !key.modifiers.shift and !key.modifiers.cmd and
            !key.modifiers.alt and !key.modifiers.ctrl;

        // Number keys for page navigation
        if (no_mods) {
            if (key.key == .@"1") {
                s.goToPage(.home);
                cx.notify();
                return true;
            }
            if (key.key == .@"2") {
                s.page = .forms;
                s.form_initialized = true;
                s.focused_field = .name;
                g.focusTextInput("form_name");
                cx.notify();
                return true;
            }
            if (key.key == .@"3") {
                s.goToPage(.scroll_demo);
                cx.notify();
                return true;
            }
            if (key.key == .@"4") {
                s.goToPage(.about);
                cx.notify();
                return true;
            }
        }

        // Arrow keys
        if (key.key == .left) {
            s.prevPage();
            cx.notify();
            return true;
        }
        if (key.key == .right) {
            s.nextPage();
            cx.notify();
            return true;
        }

        // Theme toggle
        if (key.key == .t and s.page != .forms) {
            s.toggleTheme();
            cx.notify();
            return true;
        }

        // Enter to submit form
        if (key.key == .@"return" and s.page == .forms) {
            s.submitForm();
            if (std.mem.indexOf(u8, s.form_status, "success") != null) {
                g.blurAll();
            }
            cx.notify();
            return true;
        }
    }

    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "AppState navigation" {
    var s = AppState{};
    try std.testing.expectEqual(AppState.Page.home, s.page);

    s.nextPage();
    try std.testing.expectEqual(AppState.Page.forms, s.page);

    s.nextPage();
    try std.testing.expectEqual(AppState.Page.scroll_demo, s.page);

    s.nextPage();
    try std.testing.expectEqual(AppState.Page.about, s.page);

    s.nextPage();
    try std.testing.expectEqual(AppState.Page.home, s.page);

    s.prevPage();
    try std.testing.expectEqual(AppState.Page.about, s.page);
}

test "AppState theme toggle" {
    var s = AppState{};
    try std.testing.expect(!s.is_dark);
    try std.testing.expectEqual(&Theme.light, s.theme);

    s.toggleTheme();
    try std.testing.expect(s.is_dark);
    try std.testing.expectEqual(&Theme.dark, s.theme);

    s.toggleTheme();
    try std.testing.expect(!s.is_dark);
}

test "AppState form validation" {
    var s = AppState{};

    s.submitForm();
    try std.testing.expect(std.mem.indexOf(u8, s.form_status, "name") != null);

    s.name = "Test";
    s.submitForm();
    try std.testing.expect(std.mem.indexOf(u8, s.form_status, "email") != null);

    s.email = "test@example.com";
    s.submitForm();
    try std.testing.expect(std.mem.indexOf(u8, s.form_status, "terms") != null);

    s.agree_terms = true;
    s.submitForm();
    try std.testing.expect(std.mem.indexOf(u8, s.form_status, "success") != null);
}

test "AppState clicks" {
    var s = AppState{};
    try std.testing.expectEqual(@as(u32, 0), s.click_count);

    s.increment();
    s.increment();
    try std.testing.expectEqual(@as(u32, 2), s.click_count);

    s.resetClicks();
    try std.testing.expectEqual(@as(u32, 0), s.click_count);
}

test "AppState tasks" {
    var s = AppState{};
    try std.testing.expect(!s.completed_tasks[0]);
    try std.testing.expect(s.completed_tasks[1]);
    try std.testing.expect(!s.completed_tasks[2]);

    s.toggleTask(0);
    try std.testing.expect(s.completed_tasks[0]);

    s.toggleTask(1);
    try std.testing.expect(!s.completed_tasks[1]);
}
