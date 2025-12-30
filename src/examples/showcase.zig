//! Gooey Showcase
//!
//! A comprehensive component showcase demonstrating gooey's capabilities.
//! Organized as a storybook with sections for each component type.
//!
//! Navigation:
//!   - [1-7] Jump to section
//!   - [←/→] Previous/Next section
//!   - [T] Toggle theme
//!   - [Esc] Close modals/dropdowns

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Gooey = gooey.Gooey;
const Theme = gooey.Theme;

// Components
const Button = gooey.Button;
const Checkbox = gooey.Checkbox;
const TextInput = gooey.TextInput;
const TextArea = gooey.TextArea;
const Tab = gooey.Tab;
const RadioButton = gooey.RadioButton;
const RadioGroup = gooey.RadioGroup;
const ProgressBar = gooey.ProgressBar;
const Svg = gooey.Svg;
const Icons = gooey.Icons;
const Select = gooey.Select;
const Tooltip = gooey.Tooltip;
const Modal = gooey.Modal;

// =============================================================================
// Section Navigation
// =============================================================================

const Section = enum(u8) {
    overview,
    buttons,
    inputs,
    selection,
    feedback,
    overlays,
    icons,

    const count = 7;

    fn title(self: Section) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .buttons => "Buttons",
            .inputs => "Inputs",
            .selection => "Selection",
            .feedback => "Feedback",
            .overlays => "Overlays",
            .icons => "Icons",
        };
    }

    fn next(self: Section) Section {
        const idx = @intFromEnum(self);
        return @enumFromInt((idx + 1) % count);
    }

    fn prev(self: Section) Section {
        const idx = @intFromEnum(self);
        return @enumFromInt((idx + count - 1) % count);
    }
};

// =============================================================================
// App State
// =============================================================================

const AppState = struct {
    // Navigation
    section: Section = .overview,
    theme: *const Theme = &Theme.dark,
    is_dark: bool = true,

    // Button demos
    button_clicks: u32 = 0,
    loading: bool = false,

    // Input demos
    name: []const u8 = "",
    email: []const u8 = "",
    bio: []const u8 = "",

    // Checkbox demos
    option_a: bool = true,
    option_b: bool = false,
    option_c: bool = false,
    agree_terms: bool = false,

    // Radio demos
    color_choice: u8 = 0,
    size_choice: u8 = 1,

    // Select demos
    fruit_selected: ?usize = null,
    fruit_open: bool = false,
    priority_selected: ?usize = 1,
    priority_open: bool = false,

    // Progress demos
    progress: f32 = 0.65,
    animated_progress: f32 = 0.0,
    progress_direction: bool = true,

    // Modal demos
    show_modal: bool = false,
    show_confirm: bool = false,
    confirmed_count: u32 = 0,

    // =========================================================================
    // State Methods
    // =========================================================================

    pub fn toggleTheme(self: *AppState) void {
        self.is_dark = !self.is_dark;
        self.theme = if (self.is_dark) &Theme.dark else &Theme.light;
    }

    pub fn goToSection(self: *AppState, idx: u8) void {
        if (idx < Section.count) {
            self.section = @enumFromInt(idx);
        }
    }

    pub fn nextSection(self: *AppState) void {
        self.section = self.section.next();
    }

    pub fn prevSection(self: *AppState) void {
        self.section = self.section.prev();
    }

    // Button handlers
    pub fn incrementClicks(self: *AppState) void {
        self.button_clicks += 1;
    }

    pub fn resetClicks(self: *AppState) void {
        self.button_clicks = 0;
    }

    pub fn toggleLoading(self: *AppState) void {
        self.loading = !self.loading;
    }

    // Checkbox handlers
    pub fn toggleOptionA(self: *AppState) void {
        self.option_a = !self.option_a;
    }
    pub fn toggleOptionB(self: *AppState) void {
        self.option_b = !self.option_b;
    }
    pub fn toggleOptionC(self: *AppState) void {
        self.option_c = !self.option_c;
    }
    pub fn toggleTerms(self: *AppState) void {
        self.agree_terms = !self.agree_terms;
    }

    // Radio handlers
    pub fn setColor(self: *AppState, c: u8) void {
        self.color_choice = c;
    }
    pub fn setSize(self: *AppState, s: u8) void {
        self.size_choice = s;
    }

    // Select handlers
    pub fn toggleFruit(self: *AppState) void {
        self.fruit_open = !self.fruit_open;
        self.priority_open = false;
    }
    pub fn closeFruit(self: *AppState) void {
        self.fruit_open = false;
    }
    pub fn selectFruit(self: *AppState, idx: usize) void {
        self.fruit_selected = idx;
        self.fruit_open = false;
    }

    pub fn togglePriority(self: *AppState) void {
        self.priority_open = !self.priority_open;
        self.fruit_open = false;
    }
    pub fn closePriority(self: *AppState) void {
        self.priority_open = false;
    }
    pub fn selectPriority(self: *AppState, idx: usize) void {
        self.priority_selected = idx;
        self.priority_open = false;
    }

    pub fn closeAllDropdowns(self: *AppState) void {
        self.fruit_open = false;
        self.priority_open = false;
    }

    // Progress handlers
    pub fn stepProgress(self: *AppState) void {
        if (self.progress_direction) {
            self.animated_progress += 0.1;
            if (self.animated_progress >= 1.0) {
                self.animated_progress = 1.0;
                self.progress_direction = false;
            }
        } else {
            self.animated_progress -= 0.1;
            if (self.animated_progress <= 0.0) {
                self.animated_progress = 0.0;
                self.progress_direction = true;
            }
        }
    }

    // Modal handlers
    pub fn openModal(self: *AppState) void {
        self.show_modal = true;
    }
    pub fn closeModal(self: *AppState) void {
        self.show_modal = false;
    }
    pub fn openConfirm(self: *AppState) void {
        self.show_confirm = true;
    }
    pub fn closeConfirm(self: *AppState) void {
        self.show_confirm = false;
    }
    pub fn doConfirm(self: *AppState) void {
        self.confirmed_count += 1;
        self.show_confirm = false;
    }
};

var state = AppState{};

// =============================================================================
// App Definition
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Gooey Showcase",
    .width = 1200,
    .height = 800,
    .on_event = onEvent,
});

pub fn main() !void {
    try App.main();
}

// =============================================================================
// Main Render
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const t = s.theme;
    const size = cx.windowSize();

    // Set theme for all child components
    cx.setTheme(t);

    // Using boxTracked to demonstrate source location in debugger (Cmd+Shift+I)
    cx.boxTracked(.{
        .width = size.width,
        .height = size.height,
        .background = t.bg,
        .direction = .column,
    }, .{
        TopNavBar{},
        MainContent{},

        // Modal overlays (rendered last)
        Modal(InfoModalContent){
            .id = "info-modal",
            .is_open = s.show_modal,
            .on_close = cx.update(AppState, AppState.closeModal),
            .child = InfoModalContent{},
        },

        Modal(ConfirmModalContent){
            .id = "confirm-modal",
            .is_open = s.show_confirm,
            .on_close = cx.update(AppState, AppState.closeConfirm),
            .child = ConfirmModalContent{},
        },
    }, @src());
}

// =============================================================================
// Top Navigation Bar
// =============================================================================

const TopNavBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .fill_width = true,
            .height = 60,
            .background = t.surface,
            .direction = .row,
            .padding = .{ .symmetric = .{ .x = 20, .y = 0 } },
            .gap = 8,
            .alignment = .{ .cross = .center, .main = .center },
        }, .{
            // Logo / Title
            NavLogo{},

            ui.spacer(),

            // Navigation items (horizontal)
            NavItem{ .section = .overview },
            NavItem{ .section = .buttons },
            NavItem{ .section = .inputs },
            NavItem{ .section = .selection },
            NavItem{ .section = .feedback },
            NavItem{ .section = .overlays },
            NavItem{ .section = .icons },

            ui.spacer(),

            // Theme toggle
            ThemeToggle{},
        });
    }
};

const NavLogo = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .gap = 8,
            .direction = .row,
            .alignment = .{ .cross = .center, .main = .center },
        }, .{
            gooey.Image{ .src = "assets/gooey.png", .size = 28, .fit = .cover },
            ui.text("Gooey", .{ .size = 24, .color = t.text }),
        });
    }
};

const NavItem = struct {
    section: Section,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const is_active = s.section == self.section;
        const idx = @intFromEnum(self.section);

        cx.box(.{
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .corner_radius = 6,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .background = if (is_active) t.primary.withAlpha(0.15) else ui.Color.transparent,
            .hover_background = if (is_active) t.primary.withAlpha(0.2) else t.overlay.withAlpha(0.5),
            .on_click_handler = cx.updateWith(AppState, idx, AppState.goToSection),
        }, .{
            ui.text(self.section.title(), .{
                .size = 14,
                .color = if (is_active) t.primary else t.text,
            }),
        });
    }
};

const ThemeToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();

        cx.box(.{
            .padding = .{ .all = 8 },
            .corner_radius = 6,
            .alignment = .{ .cross = .center },
            .hover_background = t.overlay.withAlpha(0.5),
            .on_click_handler = cx.update(AppState, AppState.toggleTheme),
        }, .{
            Svg{
                .path = if (s.is_dark) Icons.visibility else Icons.visibility_off,
                .size = 20,
                .color = null,
                .stroke_color = t.muted,
                .stroke_width = 1,
            },
        });
    }
};

// =============================================================================
// Main Content Area
// =============================================================================

const MainContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        // Main content area fills remaining space after nav bar
        cx.box(.{
            .grow = true,
            .fill_width = true,
            .direction = .column,
        }, .{
            SectionContent{},
        });
    }
};

const SectionContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();

        // Common scroll style for all sections
        const scroll_style = ui.ScrollStyle{
            .grow = true,
            .fill_width = true,
            .padding = .{ .all = 32 },
            .gap = 24,
            .scrollbar_size = 8,
            .track_color = t.overlay,
            .thumb_color = t.muted,
        };

        // Each section gets its own scroll container (preserves scroll position per section)
        switch (s.section) {
            .overview => cx.scroll("scroll-overview", scroll_style, .{OverviewSection{}}),
            .buttons => cx.scroll("scroll-buttons", scroll_style, .{ButtonsSection{}}),
            .inputs => cx.scroll("scroll-inputs", scroll_style, .{InputsSection{}}),
            .selection => cx.scroll("scroll-selection", scroll_style, .{SelectionSection{}}),
            .feedback => cx.scroll("scroll-feedback", scroll_style, .{FeedbackSection{}}),
            .overlays => cx.scroll("scroll-overlays", scroll_style, .{OverlaysSection{}}),
            .icons => cx.scroll("scroll-icons", scroll_style, .{IconsSection{}}),
        }
    }
};

// =============================================================================
// Reusable Card Component
// =============================================================================

const Card = struct {
    title: []const u8,
    description: ?[]const u8 = null,

    pub fn render(self: @This(), cx: *Cx, children: anytype) void {
        const t = cx.theme();

        // Using boxTracked for source location debugging
        cx.boxTracked(.{
            .fill_width = true,
            .padding = .{ .all = 24 },
            .background = t.surface,
            .corner_radius = t.radius_lg,
            .direction = .column,
            .gap = 16,
            .shadow = ui.ShadowConfig.drop(4),
        }, .{
            // Card header
            CardHeader{ .title = self.title, .description = self.description },
            // Card content
            children,
        }, @src());
    }
};

const CardHeader = struct {
    title: []const u8,
    description: ?[]const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.theme();

        if (self.description) |desc| {
            cx.box(.{ .gap = 4 }, .{
                ui.text(self.title, .{ .size = 18, .color = t.text }),
                ui.text(desc, .{ .size = 13, .color = t.muted, .wrap = .words }),
            });
        } else {
            cx.box(.{ .gap = 4 }, .{
                ui.text(self.title, .{ .size = 18, .color = t.text }),
            });
        }
    }
};

// =============================================================================
// Overview Section
// =============================================================================

const OverviewSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{ .fill_width = true, .gap = 24 }, .{
            // Hero
            cx.box(.{
                .fill_width = true,
                .padding = .{ .all = 32 },
                .background = t.primary.withAlpha(0.1),
                .corner_radius = t.radius_lg,
                .gap = 16,
                .alignment = .{ .cross = .center },
            }, .{
                ui.text("Welcome to Gooey", .{ .size = 36, .color = t.text }),
                ui.text("A GPU-accelerated UI framework for Zig", .{ .size = 18, .color = t.subtext }),
                cx.hstack(.{ .gap = 12 }, .{
                    FeatureBadge{ .icon = Icons.star, .label = "Fast" },
                    FeatureBadge{ .icon = Icons.folder, .label = "Composable" },
                    FeatureBadge{ .icon = Icons.menu, .label = "Flexible" },
                }),
            }),

            // Feature cards grid
            cx.hstack(.{ .gap = 16 }, .{
                FeatureCard{
                    .icon = Icons.play,
                    .title = "GPU Rendering",
                    .description = "Metal/WebGPU accelerated rendering for smooth 60fps UI",
                },
                FeatureCard{
                    .icon = Icons.file,
                    .title = "Pure Zig",
                    .description = "No runtime, no garbage collector, just fast native code",
                },
            }),

            cx.hstack(.{ .gap = 16 }, .{
                FeatureCard{
                    .icon = Icons.visibility,
                    .title = "Cross Platform",
                    .description = "macOS native + WebAssembly for browsers",
                },
                FeatureCard{
                    .icon = Icons.folder,
                    .title = "Component System",
                    .description = "Build UIs with composable, reusable components",
                },
            }),

            // Text alignment demo
            TextAlignmentDemo{},

            // Space distribution demo
            SpaceDistributionDemo{},

            // Quick stats
            QuickStats{},
        });
    }
};

const FeatureBadge = struct {
    icon: []const u8,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .padding = .{ .symmetric = .{ .x = 12, .y = 6 } },
            .background = t.surface,
            .corner_radius = 16,
            .direction = .row,
            .gap = 6,
            .alignment = .{ .cross = .center },
        }, .{
            Svg{
                .path = self.icon,
                .size = 14,
                .color = null,
                .stroke_color = t.primary,
                .stroke_width = 2,
            },
            ui.text(self.label, .{ .size = 12, .color = t.text }),
        });
    }
};

const FeatureCard = struct {
    icon: []const u8,
    title: []const u8,
    description: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .grow = true,
            .padding = .{ .all = 20 },
            .background = t.surface,
            .corner_radius = t.radius_md,
            .gap = 8,
        }, .{
            Svg{
                .path = self.icon,
                .size = 28,
                .color = null,
                .stroke_color = t.primary,
                .stroke_width = 2,
            },
            ui.text(self.title, .{ .size = 16, .color = t.text }),
            ui.text(self.description, .{ .size = 13, .color = t.muted, .wrap = .words }),
        });
    }
};

const TextAlignmentDemo = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = t.surface,
            .corner_radius = t.radius_md,
            .gap = 16,
        }, .{
            ui.text("Text Alignment", .{ .size = 18, .color = t.text }),

            // Three columns showing left, center, right alignment
            cx.hstack(.{ .gap = 16 }, .{
                // Left aligned
                cx.box(.{
                    .grow = true,
                    .padding = .{ .all = 16 },
                    .background = t.bg,
                    .corner_radius = t.radius_sm,
                    .gap = 8,
                }, .{
                    ui.text("Left Aligned", .{ .size = 12, .color = t.muted }),
                    ui.text("This text wraps and aligns to the left edge of its container.", .{
                        .size = 14,
                        .color = t.text,
                        .wrap = .words,
                        .alignment = .left,
                    }),
                }),
                // Center aligned
                cx.box(.{
                    .grow = true,
                    .padding = .{ .all = 16 },
                    .background = t.bg,
                    .corner_radius = t.radius_sm,
                    .gap = 8,
                }, .{
                    ui.text("Center Aligned", .{ .size = 12, .color = t.muted }),
                    ui.text("This text wraps and aligns to the center of its container.", .{
                        .size = 14,
                        .color = t.text,
                        .wrap = .words,
                        .alignment = .center,
                    }),
                }),
                // Right aligned
                cx.box(.{
                    .grow = true,
                    .padding = .{ .all = 16 },
                    .background = t.bg,
                    .corner_radius = t.radius_sm,
                    .gap = 8,
                }, .{
                    ui.text("Right Aligned", .{ .size = 12, .color = t.muted }),
                    ui.text("This text wraps and aligns to the right edge of its container.", .{
                        .size = 14,
                        .color = t.text,
                        .wrap = .words,
                        .alignment = .right,
                    }),
                }),
            }),
        });
    }
};

const SpaceDistributionDemo = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = t.surface,
            .corner_radius = t.radius_md,
            .gap = 16,
        }, .{
            ui.text("Space Distribution", .{ .size = 18, .color = t.text }),
            ui.text("Control how children are distributed along the main axis", .{ .size = 13, .color = t.muted }),

            // space-between demo
            cx.box(.{ .gap = 8 }, .{
                ui.text("space_between", .{ .size = 12, .color = t.subtext }),
                cx.box(.{
                    .fill_width = true,
                    .height = 50,
                    .padding = .{ .all = 8 },
                    .background = t.bg,
                    .corner_radius = t.radius_sm,
                    .direction = .row,
                    .alignment = .{ .main = .space_between, .cross = .center },
                }, .{
                    DistributionBox{ .label = "A" },
                    DistributionBox{ .label = "B" },
                    DistributionBox{ .label = "C" },
                }),
            }),

            // space-around demo
            cx.box(.{ .gap = 8 }, .{
                ui.text("space_around", .{ .size = 12, .color = t.subtext }),
                cx.box(.{
                    .fill_width = true,
                    .height = 50,
                    .padding = .{ .all = 8 },
                    .background = t.bg,
                    .corner_radius = t.radius_sm,
                    .direction = .row,
                    .alignment = .{ .main = .space_around, .cross = .center },
                }, .{
                    DistributionBox{ .label = "A" },
                    DistributionBox{ .label = "B" },
                    DistributionBox{ .label = "C" },
                }),
            }),

            // space-evenly demo
            cx.box(.{ .gap = 8 }, .{
                ui.text("space_evenly", .{ .size = 12, .color = t.subtext }),
                cx.box(.{
                    .fill_width = true,
                    .height = 50,
                    .padding = .{ .all = 8 },
                    .background = t.bg,
                    .corner_radius = t.radius_sm,
                    .direction = .row,
                    .alignment = .{ .main = .space_evenly, .cross = .center },
                }, .{
                    DistributionBox{ .label = "A" },
                    DistributionBox{ .label = "B" },
                    DistributionBox{ .label = "C" },
                }),
            }),
        });
    }
};

const DistributionBox = struct {
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .width = 40,
            .height = 30,
            .background = t.primary,
            .corner_radius = 4,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text(self.label, .{ .size = 14, .color = ui.Color.white }),
        });
    }
};

const QuickStats = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = t.surface,
            .corner_radius = t.radius_md,
            .direction = .row,
            .gap = 32,
            .alignment = .{ .cross = .center, .main = .center },
        }, .{
            StatItem{ .value = "7", .label = "Components" },
            StatItem{ .value = "60", .label = "FPS Target" },
            StatItem{ .value = "0", .label = "Dependencies" },
        });
    }
};

const StatItem = struct {
    value: []const u8,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
            ui.text(self.value, .{ .size = 28, .color = t.primary }),
            ui.text(self.label, .{ .size = 12, .color = t.muted }),
        });
    }
};

// =============================================================================
// Buttons Section
// =============================================================================

const ButtonsSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.boxTracked(.{ .fill_width = true, .gap = 24 }, .{
            ButtonVariantsCard{},
            ButtonSizesCard{},
            ButtonInteractiveCard{},
        }, @src());
    }
};

const ButtonVariantsCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();
        const card = Card{ .title = "Button Variants", .description = "Different button styles for various contexts" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 12, .alignment = .center }, .{
                Button{ .label = "Primary", .variant = .primary },
                Button{ .label = "Secondary", .variant = .secondary },
                Button{ .label = "Danger", .variant = .danger },
            }),

            cx.hstack(.{ .gap = 12, .alignment = .center }, .{
                Button{ .label = "Disabled", .variant = .primary, .enabled = false },
                Tooltip(Button){
                    .text = "This button has a tooltip!",
                    .position = .top,
                    .background = t.overlay,
                    .child = Button{ .label = "With Tooltip", .variant = .secondary },
                },
            }),
        });
    }
};

const ButtonSizesCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const card = Card{ .title = "Button Sizes", .description = "Small, medium, and large variants" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 12, .alignment = .center }, .{
                Button{ .label = "Small", .size = .small },
                Button{ .label = "Medium", .size = .medium },
                Button{ .label = "Large", .size = .large },
            }),
        });
    }
};

const ButtonInteractiveCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const card = Card{ .title = "Interactive Demo", .description = "Click to see state updates" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                Button{
                    .label = "Click Me!",
                    .variant = .primary,
                    .on_click_handler = cx.update(AppState, AppState.incrementClicks),
                },
                Button{
                    .label = "Reset",
                    .variant = .secondary,
                    .on_click_handler = cx.update(AppState, AppState.resetClicks),
                },
                cx.box(.{
                    .padding = .{ .symmetric = .{ .x = 16, .y = 8 } },
                    .background = t.overlay,
                    .corner_radius = t.radius_md,
                }, .{
                    ui.textFmt("Clicks: {d}", .{s.button_clicks}, .{ .size = 14, .color = t.text }),
                }),
            }),
        });
    }
};

// =============================================================================
// Inputs Section
// =============================================================================

const InputsSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .fill_width = true, .gap = 24 }, .{
            TextInputCard{},
            TextAreaCard{},
        });
    }
};

const TextInputCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const card = Card{ .title = "Text Input", .description = "Single-line text entry with placeholder and binding" };

        card.render(cx, .{
            cx.box(.{ .gap = 16 }, .{
                cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                    TextInput{
                        .id = "name-input",
                        .placeholder = "Your name",
                        .width = 200,
                        .bind = &s.name,
                        // Uses theme defaults: background=bg, border=border, etc.
                    },
                    TextInput{
                        .id = "email-input",
                        .placeholder = "Email address",
                        .width = 200,
                        .bind = &s.email,
                    },
                }),
                cx.hstack(.{ .gap = 8 }, .{
                    ui.text("Name:", .{ .size = 13, .color = t.muted }),
                    ui.text(if (s.name.len > 0) s.name else "(empty)", .{ .size = 13, .color = t.text }),
                    ui.text("  Email:", .{ .size = 13, .color = t.muted }),
                    ui.text(if (s.email.len > 0) s.email else "(empty)", .{ .size = 13, .color = t.text }),
                }),
            }),
        });
    }
};

const TextAreaCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const card = Card{ .title = "Text Area", .description = "Multi-line text entry for longer content" };

        card.render(cx, .{
            TextArea{
                .id = "bio-input",
                .placeholder = "Tell us about yourself...",
                .width = 400,
                .height = 120,
                .bind = &cx.state(AppState).bio,
                // Uses theme defaults for all colors
            },
        });
    }
};

// =============================================================================
// Selection Section
// =============================================================================

const SelectionSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .fill_width = true, .gap = 24 }, .{
            CheckboxCard{},
            RadioCard{},
            SelectCard{},
        });
    }
};

const CheckboxCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const card = Card{ .title = "Checkbox", .description = "Toggle options on or off" };

        card.render(cx, .{
            cx.box(.{ .gap = 12 }, .{
                Checkbox{
                    .id = "opt-a",
                    .checked = s.option_a,
                    .label = "Option A (checked by default)",
                    .on_click_handler = cx.update(AppState, AppState.toggleOptionA),
                    // Uses theme defaults
                },
                Checkbox{
                    .id = "opt-b",
                    .checked = s.option_b,
                    .label = "Option B",
                    .on_click_handler = cx.update(AppState, AppState.toggleOptionB),
                },
                Checkbox{
                    .id = "opt-c",
                    .checked = s.option_c,
                    .label = "Option C (success color)",
                    .on_click_handler = cx.update(AppState, AppState.toggleOptionC),
                    // Override just the checked color
                    .checked_background = t.success,
                },
            }),
        });
    }
};

const RadioCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const card = Card{ .title = "Radio Buttons", .description = "Select one option from a group" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 32, .alignment = .start }, .{
                // Color selection - vertical
                cx.box(.{ .gap = 8 }, .{
                    ui.text("Color", .{ .size = 13, .color = t.muted }),
                    RadioButton{
                        .label = "Red",
                        .is_selected = s.color_choice == 0,
                        .on_click_handler = cx.updateWith(AppState, @as(u8, 0), AppState.setColor),
                        .selected_color = t.danger,
                    },
                    RadioButton{
                        .label = "Green",
                        .is_selected = s.color_choice == 1,
                        .on_click_handler = cx.updateWith(AppState, @as(u8, 1), AppState.setColor),
                        .selected_color = t.success,
                    },
                    RadioButton{
                        .label = "Blue",
                        .is_selected = s.color_choice == 2,
                        .on_click_handler = cx.updateWith(AppState, @as(u8, 2), AppState.setColor),
                        .selected_color = t.primary,
                    },
                }),
                // Size selection - horizontal using RadioGroup
                cx.box(.{ .gap = 8 }, .{
                    ui.text("Size", .{ .size = 13, .color = t.muted }),
                    RadioGroup{
                        .id = "size-group",
                        .options = &.{ "S", "M", "L", "XL" },
                        .selected = s.size_choice,
                        .handlers = &.{
                            cx.updateWith(AppState, @as(u8, 0), AppState.setSize),
                            cx.updateWith(AppState, @as(u8, 1), AppState.setSize),
                            cx.updateWith(AppState, @as(u8, 2), AppState.setSize),
                            cx.updateWith(AppState, @as(u8, 3), AppState.setSize),
                        },
                        .direction = .row,
                        .gap = 16,
                        // Uses theme defaults
                    },
                }),
            }),
        });
    }
};

const fruit_options = [_][]const u8{ "Apple", "Banana", "Cherry", "Dragon Fruit", "Elderberry" };
const priority_options = [_][]const u8{ "Low", "Medium", "High", "Critical" };

const SelectCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const card = Card{ .title = "Select / Dropdown", .description = "Choose from a list of options" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 24, .alignment = .start }, .{
                cx.box(.{ .gap = 8 }, .{
                    ui.text("Fruit", .{ .size = 13, .color = t.muted }),
                    Select{
                        .id = "fruit-select",
                        .options = &fruit_options,
                        .selected = s.fruit_selected,
                        .placeholder = "Choose a fruit...",
                        .is_open = s.fruit_open,
                        .width = 180,
                        .on_toggle_handler = cx.update(AppState, AppState.toggleFruit),
                        .on_close_handler = cx.update(AppState, AppState.closeFruit),
                        .handlers = &.{
                            cx.updateWith(AppState, @as(usize, 0), AppState.selectFruit),
                            cx.updateWith(AppState, @as(usize, 1), AppState.selectFruit),
                            cx.updateWith(AppState, @as(usize, 2), AppState.selectFruit),
                            cx.updateWith(AppState, @as(usize, 3), AppState.selectFruit),
                            cx.updateWith(AppState, @as(usize, 4), AppState.selectFruit),
                        },
                        // Uses theme defaults
                    },
                }),
                cx.box(.{ .gap = 8 }, .{
                    ui.text("Priority", .{ .size = 13, .color = t.muted }),
                    Select{
                        .id = "priority-select",
                        .options = &priority_options,
                        .selected = s.priority_selected,
                        .is_open = s.priority_open,
                        .width = 150,
                        .on_toggle_handler = cx.update(AppState, AppState.togglePriority),
                        .on_close_handler = cx.update(AppState, AppState.closePriority),
                        .handlers = &.{
                            cx.updateWith(AppState, @as(usize, 0), AppState.selectPriority),
                            cx.updateWith(AppState, @as(usize, 1), AppState.selectPriority),
                            cx.updateWith(AppState, @as(usize, 2), AppState.selectPriority),
                            cx.updateWith(AppState, @as(usize, 3), AppState.selectPriority),
                        },
                        // Override focus border color
                        .focus_border_color = t.warning,
                    },
                }),
            }),
        });
    }
};

// =============================================================================
// Feedback Section
// =============================================================================

const FeedbackSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .fill_width = true, .gap = 24 }, .{
            ProgressCard{},
            TooltipCard{},
        });
    }
};

const ProgressCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const card = Card{ .title = "Progress Bar", .description = "Show completion status" };

        card.render(cx, .{
            cx.box(.{ .gap = 16 }, .{
                cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                    ui.text("65%", .{ .size = 13, .color = t.muted }),
                    ProgressBar{
                        .progress = 0.65,
                        .width = 200,
                        .height = 8,
                        // Uses theme defaults (overlay bg, primary fill)
                    },
                }),
                cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                    ui.text("25%", .{ .size = 13, .color = t.muted }),
                    ProgressBar{
                        .progress = 0.25,
                        .width = 200,
                        .height = 8,
                        .fill = t.warning,
                    },
                }),
                cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                    ui.text("100%", .{ .size = 13, .color = t.muted }),
                    ProgressBar{
                        .progress = 1.0,
                        .width = 200,
                        .height = 8,
                        .fill = t.success,
                    },
                }),
                cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                    Button{
                        .label = "Step Progress",
                        .variant = .secondary,
                        .size = .small,
                        .on_click_handler = cx.update(AppState, AppState.stepProgress),
                    },
                    ProgressBar{
                        .progress = s.animated_progress,
                        .width = 150,
                        .height = 10,
                        .fill = t.accent,
                    },
                    ui.textFmt("{d}%", .{@as(u32, @intFromFloat(s.animated_progress * 100))}, .{
                        .size = 13,
                        .color = t.text,
                    }),
                }),
            }),
        });
    }
};

const TooltipCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const card = Card{ .title = "Tooltips", .description = "Hover to see contextual information" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                Tooltip(Button){
                    .text = "Appears above",
                    .position = .top,
                    .child = Button{ .label = "Top", .variant = .secondary, .size = .small },
                },
                Tooltip(Button){
                    .text = "Appears below",
                    .position = .bottom,
                    .child = Button{ .label = "Bottom", .variant = .secondary, .size = .small },
                },
                Tooltip(Button){
                    .text = "Appears left",
                    .position = .left,
                    .child = Button{ .label = "Left", .variant = .secondary, .size = .small },
                },
                Tooltip(Button){
                    .text = "Appears right",
                    .position = .right,
                    .child = Button{ .label = "Right", .variant = .secondary, .size = .small },
                },
            }),
        });
    }
};

// =============================================================================
// Overlays Section
// =============================================================================

const OverlaysSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .fill_width = true, .gap = 24 }, .{
            ModalCard{},
        });
    }
};

const ModalCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = cx.theme();
        const card = Card{ .title = "Modal Dialogs", .description = "Overlay dialogs for important interactions" };

        card.render(cx, .{
            cx.box(.{ .gap = 16 }, .{
                cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                    Button{
                        .label = "Info Modal",
                        .variant = .primary,
                        .on_click_handler = cx.update(AppState, AppState.openModal),
                    },
                    Button{
                        .label = "Confirm Action",
                        .variant = .danger,
                        .on_click_handler = cx.update(AppState, AppState.openConfirm),
                    },
                }),
                cx.hstack(.{ .gap = 8 }, .{
                    ui.text("Confirmed actions:", .{ .size = 13, .color = t.muted }),
                    ui.textFmt("{d}", .{s.confirmed_count}, .{ .size = 13, .color = t.text }),
                }),
            }),
        });
    }
};

const InfoModalContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{ .gap = 16, .fill_width = true }, .{
            ui.text("Information", .{ .size = 20, .color = t.text }),
            ui.text("This is a modal dialog. Click outside or press Escape to close.", .{
                .size = 14,
                .color = t.subtext,
                .wrap = .words,
            }),
            Button{
                .label = "Got it",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.closeModal),
            },
        });
    }
};

const ConfirmModalContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();

        cx.box(.{ .gap = 20, .fill_width = true }, .{
            ui.text("Confirm Action", .{ .size = 20, .color = t.text }),
            ui.text("Are you sure you want to proceed? This action will be counted.", .{
                .size = 14,
                .color = t.subtext,
                .wrap = .words,
            }),
            cx.hstack(.{ .gap = 12, .alignment = .end }, .{
                ui.spacer(),
                Button{
                    .label = "Cancel",
                    .variant = .secondary,
                    .on_click_handler = cx.update(AppState, AppState.closeConfirm),
                },
                Button{
                    .label = "Confirm",
                    .variant = .danger,
                    .on_click_handler = cx.update(AppState, AppState.doConfirm),
                },
            }),
        });
    }
};

// =============================================================================
// Icons Section
// =============================================================================

const IconsSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .fill_width = true, .gap = 24 }, .{
            BasicIconsCard{},
            StyledIconsCard{},
            CustomPathsCard{},
        });
    }
};

const BasicIconsCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();
        const card = Card{ .title = "Basic Icons", .description = "Built-in icon set with stroke rendering" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 20, .alignment = .center }, .{
                IconWithLabel{ .icon = Icons.folder, .label = "Folder" },
                IconWithLabel{ .icon = Icons.search, .label = "Search" },
                IconWithLabel{ .icon = Icons.edit, .label = "Edit" },
                IconWithLabel{ .icon = Icons.favorite, .label = "Heart" },
                IconWithLabel{ .icon = Icons.file, .label = "File" },
                IconWithLabel{ .icon = Icons.warning, .label = "Alert" },
                IconWithLabel{ .icon = Icons.menu, .label = "Menu" },
                IconWithLabel{ .icon = Icons.download, .label = "Download" },
            }),
            cx.hstack(.{ .gap = 20, .alignment = .center }, .{
                IconWithLabel{ .icon = Icons.check, .label = "Check", .color = t.success },
                IconWithLabel{ .icon = Icons.close, .label = "Close", .color = t.danger },
                IconWithLabel{ .icon = Icons.warning, .label = "Warning", .color = t.warning },
                IconWithLabel{ .icon = Icons.info, .label = "Info", .color = t.primary },
                IconWithLabel{ .icon = Icons.star, .label = "Star", .color = t.accent },
                IconWithLabel{ .icon = Icons.favorite, .label = "Heart", .color = t.danger },
            }),
        });
    }
};

const IconWithLabel = struct {
    icon: []const u8,
    label: []const u8,
    color: ?ui.Color = null,

    pub fn render(self: @This(), cx: *Cx) void {
        const t = cx.theme();
        const icon_color = self.color orelse t.text;

        cx.box(.{ .gap = 6, .alignment = .{ .cross = .center } }, .{
            Svg{
                .path = self.icon,
                .size = 24,
                .color = null,
                .stroke_color = icon_color,
                .stroke_width = 2,
            },
            ui.text(self.label, .{ .size = 11, .color = t.muted }),
        });
    }
};

const StyledIconsCard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();
        const card = Card{ .title = "Icon Styles", .description = "Different sizes and stroke widths" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 24, .alignment = .end }, .{
                cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Svg{ .path = Icons.star_outline, .size = 16, .color = null, .stroke_color = t.primary, .stroke_width = 1.5 },
                    ui.text("16px", .{ .size = 11, .color = t.muted }),
                }),
                cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Svg{ .path = Icons.star_outline, .size = 24, .color = null, .stroke_color = t.primary, .stroke_width = 2 },
                    ui.text("24px", .{ .size = 11, .color = t.muted }),
                }),
                cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Svg{ .path = Icons.star_outline, .size = 32, .color = null, .stroke_color = t.primary, .stroke_width = 2 },
                    ui.text("32px", .{ .size = 11, .color = t.muted }),
                }),
                cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Svg{ .path = Icons.star_outline, .size = 48, .color = null, .stroke_color = t.primary, .stroke_width = 2.5 },
                    ui.text("48px", .{ .size = 11, .color = t.muted }),
                }),
            }),
            cx.hstack(.{ .gap = 24, .alignment = .center }, .{
                // Filled star
                Svg{ .path = Icons.star, .size = 32, .color = t.warning },
                // Stroke only
                Svg{ .path = Icons.star_outline, .size = 32, .color = null, .stroke_color = t.warning, .stroke_width = 2 },
                // Fill + stroke
                Svg{ .path = Icons.favorite, .size = 32, .color = t.danger.withAlpha(0.3), .stroke_color = t.danger, .stroke_width = 2 },
            }),
        });
    }
};

const CustomPathsCard = struct {
    // Custom SVG paths
    const circle_path = "M12 2 A10 10 0 1 1 12 22 A10 10 0 1 1 12 2";
    const wave_path = "M2 12 Q6 6 12 12 T22 12";
    const rounded_rect = "M6 2 L18 2 A4 4 0 0 1 22 6 L22 18 A4 4 0 0 1 18 22 L6 22 A4 4 0 0 1 2 18 L2 6 A4 4 0 0 1 6 2 Z";

    pub fn render(_: @This(), cx: *Cx) void {
        const t = cx.theme();
        const card = Card{ .title = "Custom SVG Paths", .description = "Arcs, beziers, and custom shapes" };

        card.render(cx, .{
            cx.hstack(.{ .gap = 24, .alignment = .center }, .{
                cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Svg{ .path = circle_path, .size = 32, .color = null, .stroke_color = t.primary, .stroke_width = 2 },
                    ui.text("Circle (Arc)", .{ .size = 11, .color = t.muted }),
                }),
                cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Svg{ .path = wave_path, .size = 32, .color = null, .stroke_color = t.accent, .stroke_width = 2 },
                    ui.text("Wave (Bezier)", .{ .size = 11, .color = t.muted }),
                }),
                cx.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Svg{ .path = rounded_rect, .size = 32, .color = t.surface, .stroke_color = t.text, .stroke_width = 1.5 },
                    ui.text("Rounded Rect", .{ .size = 11, .color = t.muted }),
                }),
            }),
        });
    }
};

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(cx: *Cx, event: gooey.InputEvent) bool {
    const s = cx.state(AppState);
    const g = cx.gooey();

    // Let text widgets handle their input first
    if (g.getFocusedTextInput() != null or g.getFocusedTextArea() != null) {
        return false;
    }

    if (event == .key_down) {
        const key = event.key_down;

        // Escape closes modals/dropdowns
        if (key.key == .escape) {
            if (s.show_modal) {
                s.closeModal();
                cx.notify();
                return true;
            }
            if (s.show_confirm) {
                s.closeConfirm();
                cx.notify();
                return true;
            }
            if (s.fruit_open or s.priority_open) {
                s.closeAllDropdowns();
                cx.notify();
                return true;
            }
        }

        // T toggles theme
        if (key.key == .t) {
            s.toggleTheme();
            cx.notify();
            return true;
        }

        // Arrow keys for navigation
        if (key.key == .left) {
            s.prevSection();
            cx.notify();
            return true;
        }
        if (key.key == .right) {
            s.nextSection();
            cx.notify();
            return true;
        }

        // Number keys for direct section access
        if (key.key == .@"1") {
            s.goToSection(0);
            cx.notify();
            return true;
        }
        if (key.key == .@"2") {
            s.goToSection(1);
            cx.notify();
            return true;
        }
        if (key.key == .@"3") {
            s.goToSection(2);
            cx.notify();
            return true;
        }
        if (key.key == .@"4") {
            s.goToSection(3);
            cx.notify();
            return true;
        }
        if (key.key == .@"5") {
            s.goToSection(4);
            cx.notify();
            return true;
        }
        if (key.key == .@"6") {
            s.goToSection(5);
            cx.notify();
            return true;
        }
        if (key.key == .@"7") {
            s.goToSection(6);
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
    try std.testing.expectEqual(Section.overview, s.section);

    s.nextSection();
    try std.testing.expectEqual(Section.buttons, s.section);

    s.nextSection();
    try std.testing.expectEqual(Section.inputs, s.section);

    s.prevSection();
    try std.testing.expectEqual(Section.buttons, s.section);

    s.goToSection(5);
    try std.testing.expectEqual(Section.overlays, s.section);
}

test "AppState theme toggle" {
    var s = AppState{};
    try std.testing.expect(s.is_dark);
    try std.testing.expectEqual(&Theme.dark, s.theme);

    s.toggleTheme();
    try std.testing.expect(!s.is_dark);
    try std.testing.expectEqual(&Theme.light, s.theme);

    s.toggleTheme();
    try std.testing.expect(s.is_dark);
}

test "AppState clicks" {
    var s = AppState{};
    try std.testing.expectEqual(@as(u32, 0), s.button_clicks);

    s.incrementClicks();
    s.incrementClicks();
    try std.testing.expectEqual(@as(u32, 2), s.button_clicks);

    s.resetClicks();
    try std.testing.expectEqual(@as(u32, 0), s.button_clicks);
}

test "AppState checkboxes" {
    var s = AppState{};
    try std.testing.expect(s.option_a);
    try std.testing.expect(!s.option_b);

    s.toggleOptionA();
    try std.testing.expect(!s.option_a);

    s.toggleOptionB();
    try std.testing.expect(s.option_b);
}

test "AppState select" {
    var s = AppState{};
    try std.testing.expect(s.fruit_selected == null);
    try std.testing.expect(!s.fruit_open);

    s.toggleFruit();
    try std.testing.expect(s.fruit_open);

    s.selectFruit(2);
    try std.testing.expectEqual(@as(?usize, 2), s.fruit_selected);
    try std.testing.expect(!s.fruit_open);
}

test "AppState modals" {
    var s = AppState{};
    try std.testing.expect(!s.show_modal);
    try std.testing.expectEqual(@as(u32, 0), s.confirmed_count);

    s.openConfirm();
    try std.testing.expect(s.show_confirm);

    s.doConfirm();
    try std.testing.expect(!s.show_confirm);
    try std.testing.expectEqual(@as(u32, 1), s.confirmed_count);
}
