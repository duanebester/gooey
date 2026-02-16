//! Form Validation Example
//!
//! Demonstrates form validation patterns in Gooey:
//! - Using `gooey.validation` for pure validation functions
//! - Using `gooey.ValidatedTextInput` for convenient form fields
//! - Per-field touched tracking with `on_blur_handler`
//! - Real-time validation display
//! - Form submission with full validation
//! - Form reset functionality
//! - Focus management: auto-focus first invalid field on submit
//!
//! Accessibility Features:
//! - `aria-invalid` automatically set on invalid fields
//! - `aria-required` set on required fields
//! - `aria-describedby` links inputs to their error messages
//! - Live regions announce validation errors to screen readers
//!
//! This example shows two approaches:
//! 1. ValidatedTextInput: All-in-one component with label, input, and error
//! 2. Manual pattern: TextInput + separate error display

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const TextInput = gooey.TextInput;
const ValidatedTextInput = gooey.ValidatedTextInput;
const validation = gooey.validation;

// =============================================================================
// Form State
// =============================================================================

const FormState = struct {
    username: []const u8 = "",
    email: []const u8 = "",
    password: []const u8 = "",
    confirm_password: []const u8 = "",
    touched: TouchedFields = .{},
    submitted: bool = false,
    show_success: bool = false,
    pending_focus: ?[]const u8 = null,

    const TouchedFields = struct {
        username: bool = false,
        email: bool = false,
        password: bool = false,
        confirm_password: bool = false,

        fn touchAll(self: *TouchedFields) void {
            self.username = true;
            self.email = true;
            self.password = true;
            self.confirm_password = true;
        }

        fn reset(self: *TouchedFields) void {
            self.username = false;
            self.email = false;
            self.password = false;
            self.confirm_password = false;
        }

        fn anyTouched(self: TouchedFields) bool {
            return self.username or self.email or self.password or self.confirm_password;
        }
    };

    // =========================================================================
    // Validation
    // =========================================================================

    pub fn validateUsername(self: *const FormState) ?[]const u8 {
        return validation.all(self.username, .{
            validation.required,
            validation.minLengthValidator(3),
            validation.maxLengthValidator(20),
            validation.alphanumeric,
        });
    }

    pub fn validateEmail(self: *const FormState) ?[]const u8 {
        return validation.all(self.email, .{
            validation.required,
            validation.email,
        });
    }

    pub fn validatePassword(self: *const FormState) ?[]const u8 {
        return validation.all(self.password, .{
            validation.required,
            validation.minLengthValidator(8),
        });
    }

    pub fn validateConfirmPassword(self: *const FormState) ?[]const u8 {
        if (validation.required(self.confirm_password)) |err| return err;
        return validation.matches(self.confirm_password, self.password);
    }

    pub fn isFormValid(self: *const FormState) bool {
        return self.validateUsername() == null and
            self.validateEmail() == null and
            self.validatePassword() == null and
            self.validateConfirmPassword() == null;
    }

    pub fn getFirstInvalidField(self: *const FormState) ?[]const u8 {
        if (self.validateUsername() != null) return "username";
        if (self.validateEmail() != null) return "email";
        if (self.validatePassword() != null) return "password";
        if (self.validateConfirmPassword() != null) return "confirm-password";
        return null;
    }

    // =========================================================================
    // Event Handlers
    // =========================================================================

    pub fn onUsernameBlur(self: *FormState) void {
        self.touched.username = true;
    }

    pub fn onEmailBlur(self: *FormState) void {
        self.touched.email = true;
    }

    pub fn onPasswordBlur(self: *FormState) void {
        self.touched.password = true;
    }

    pub fn onConfirmPasswordBlur(self: *FormState) void {
        self.touched.confirm_password = true;
    }

    pub fn submit(self: *FormState) void {
        self.touched.touchAll();
        self.submitted = true;

        if (self.isFormValid()) {
            self.show_success = true;
            self.pending_focus = null;
        } else {
            self.pending_focus = self.getFirstInvalidField();
        }
    }

    pub fn reset(self: *FormState) void {
        self.username = "";
        self.email = "";
        self.password = "";
        self.confirm_password = "";
        self.touched.reset();
        self.submitted = false;
        self.show_success = false;
        self.pending_focus = null;
    }

    pub fn dismissSuccess(self: *FormState) void {
        self.show_success = false;
    }
};

// =============================================================================
// App Setup
// =============================================================================

var state = FormState{};

const App = gooey.App(FormState, &state, render, .{
    .title = "Form Validation Example",
    .width = 600,
    .height = 700,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Main Render
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(FormState);
    const size = cx.windowSize();
    const t = cx.theme();

    cx.render(ui.scroll("form-validation", .{
        .width = size.width,
        .height = size.height,
        .background = t.bg,
        .padding = .{ .all = 32 },
        .gap = 24,
    }, .{
        FormHeader{},
        SuccessMessage{ .show = s.show_success },
        FormContainer{
            .username = s.username,
            .email = s.email,
            .password = s.password,
            .confirm_password = s.confirm_password,
            .touched = s.touched,
            .is_valid = s.isFormValid(),
            .submitted = s.submitted,
            .username_error = s.validateUsername(),
            .email_error = s.validateEmail(),
            .password_error = s.validatePassword(),
            .confirm_error = s.validateConfirmPassword(),
        },
        DebugPanel{
            .username = s.username,
            .email = s.email,
            .is_valid = s.isFormValid(),
            .touched = s.touched,
        },
    }));
}

// =============================================================================
// Components
// =============================================================================

const FormHeader = struct {
    pub fn render(_: FormHeader, cx: *Cx) void {
        const t = cx.theme();

        cx.render(ui.box(.{ .direction = .column, .gap = 8 }, .{
            ui.text("Form Validation Example", .{
                .size = 28,
                .weight = .bold,
                .color = t.text,
            }),
            ui.text("Demonstrates validation utilities and ValidatedTextInput component", .{
                .size = 14,
                .color = t.subtext,
            }),
        }));
    }
};

const SuccessMessage = struct {
    show: bool,

    pub fn render(self: SuccessMessage, cx: *Cx) void {
        if (!self.show) return;

        const t = cx.theme();

        cx.render(ui.box(.{
            .padding = .{ .all = 16 },
            .background = t.success.withAlpha(0.15),
            .border_color = t.success,
            .border_width = .{ .all = 1 },
            .corner_radius = t.radius_md,
            .direction = .row,
            .gap = 12,
            .alignment = .{ .cross = .center },
        }, .{
            ui.text("✓", .{ .size = 20, .weight = .bold, .color = t.success }),
            ui.box(.{ .direction = .column, .gap = 4, .grow = true }, .{
                ui.text("Form submitted successfully!", .{
                    .size = 16,
                    .weight = .semibold,
                    .color = t.success,
                }),
                ui.text("All fields validated correctly.", .{
                    .size = 14,
                    .color = t.text,
                }),
            }),
            Button{
                .id = "dismiss-success",
                .label = "Dismiss",
                .variant = .secondary,
                .on_click_handler = cx.update(FormState, FormState.dismissSuccess),
            },
        }));
    }
};

const FormContainer = struct {
    username: []const u8,
    email: []const u8,
    password: []const u8,
    confirm_password: []const u8,
    touched: FormState.TouchedFields,
    is_valid: bool,
    submitted: bool,
    username_error: ?[]const u8,
    email_error: ?[]const u8,
    password_error: ?[]const u8,
    confirm_error: ?[]const u8,

    pub fn render(self: FormContainer, cx: *Cx) void {
        const t = cx.theme();

        cx.render(ui.box(.{
            .direction = .column,
            .gap = 24,
            .padding = .{ .all = 24 },
            .background = t.surface,
            .corner_radius = t.radius_lg,
        }, .{
            SectionHeader{ .title = "Using ValidatedTextInput" },
            ValidatedInputFields{
                .username = self.username,
                .email = self.email,
                .username_error = self.username_error,
                .email_error = self.email_error,
                .username_touched = self.touched.username,
                .email_touched = self.touched.email,
            },
            Divider{},
            SectionHeader{ .title = "Manual Pattern (for comparison)" },
            ManualInputFields{
                .password = self.password,
                .confirm_password = self.confirm_password,
                .password_error = if (self.touched.password) self.password_error else null,
                .confirm_error = if (self.touched.confirm_password) self.confirm_error else null,
            },
            Divider{},
            FormActions{ .is_valid = self.is_valid, .submitted = self.submitted },
        }));
    }
};

const SectionHeader = struct {
    title: []const u8,

    pub fn render(self: SectionHeader, cx: *Cx) void {
        const t = cx.theme();

        cx.render(ui.text(self.title, .{
            .size = 16,
            .weight = .semibold,
            .color = t.text,
        }));
    }
};

const Divider = struct {
    pub fn render(_: Divider, cx: *Cx) void {
        const t = cx.theme();
        cx.render(ui.box(.{ .height = 1, .fill_width = true, .background = t.border }, .{}));
    }
};

const ValidatedInputFields = struct {
    username: []const u8,
    email: []const u8,
    username_error: ?[]const u8,
    email_error: ?[]const u8,
    username_touched: bool,
    email_touched: bool,

    pub fn render(self: ValidatedInputFields, cx: *Cx) void {
        const s = cx.state(FormState);

        cx.render(ui.box(.{ .direction = .column, .gap = 28 }, .{
            ValidatedTextInput{
                .id = "username",
                .label = "Username",
                .required_indicator = true,
                .placeholder = "Enter username (3-20 chars, alphanumeric)",
                .bind = @constCast(&s.username),
                .error_message = self.username_error,
                .show_error = self.username_touched,
                .help_text = "Letters and numbers only",
                .on_blur_handler = cx.update(FormState, FormState.onUsernameBlur),
                .width = 400,
                .gap = 10,
            },
            ValidatedTextInput{
                .id = "email",
                .label = "Email Address",
                .required_indicator = true,
                .placeholder = "you@example.com",
                .bind = @constCast(&s.email),
                .error_message = self.email_error,
                .show_error = self.email_touched,
                .on_blur_handler = cx.update(FormState, FormState.onEmailBlur),
                .width = 400,
                .gap = 10,
            },
        }));
    }
};

const ManualInputFields = struct {
    password: []const u8,
    confirm_password: []const u8,
    password_error: ?[]const u8,
    confirm_error: ?[]const u8,

    pub fn render(self: ManualInputFields, cx: *Cx) void {
        const s = cx.state(FormState);
        const t = cx.theme();

        // Helper to create error text or placeholder
        const password_helper = if (self.password_error) |msg|
            ui.text(msg, .{ .size = 12, .color = t.danger })
        else
            ui.text(" ", .{ .size = 12, .color = ui.Color.transparent });

        const confirm_helper = if (self.confirm_error) |msg|
            ui.text(msg, .{ .size = 12, .color = t.danger })
        else
            ui.text(" ", .{ .size = 12, .color = ui.Color.transparent });

        cx.render(ui.box(.{ .direction = .column, .gap = 28 }, .{
            // Password field
            ui.box(.{ .direction = .column, .gap = 10, .width = 400 }, .{
                // Label
                ui.box(.{ .direction = .row, .gap = 2 }, .{
                    ui.text("Password", .{ .size = 14, .weight = .medium, .color = t.text }),
                    ui.text("*", .{ .size = 14, .weight = .bold, .color = t.danger }),
                }),
                // Input
                ui.input("password", .{
                    .placeholder = "Enter password (min 8 characters)",
                    .secure = true,
                    .bind = @constCast(&s.password),
                    .width = 400,
                    .background = t.surface,
                    .border_color = if (self.password_error != null) t.danger else t.border,
                    .border_color_focused = if (self.password_error != null) t.danger else t.border_focus,
                    .corner_radius = t.radius_md,
                    .text_color = t.text,
                    .placeholder_color = t.muted,
                    .selection_color = t.primary.withAlpha(0.3),
                    .cursor_color = t.text,
                    .on_blur_handler = cx.update(FormState, FormState.onPasswordBlur),
                }),
                // Error text (always 16px tall)
                ui.box(.{ .height = 16 }, .{password_helper}),
            }),
            // Confirm password field
            ui.box(.{ .direction = .column, .gap = 10, .width = 400 }, .{
                // Label
                ui.box(.{ .direction = .row, .gap = 2 }, .{
                    ui.text("Confirm Password", .{ .size = 14, .weight = .medium, .color = t.text }),
                    ui.text("*", .{ .size = 14, .weight = .bold, .color = t.danger }),
                }),
                // Input
                ui.input("confirm-password", .{
                    .placeholder = "Re-enter your password",
                    .secure = true,
                    .bind = @constCast(&s.confirm_password),
                    .width = 400,
                    .background = t.surface,
                    .border_color = if (self.confirm_error != null) t.danger else t.border,
                    .border_color_focused = if (self.confirm_error != null) t.danger else t.border_focus,
                    .corner_radius = t.radius_md,
                    .text_color = t.text,
                    .placeholder_color = t.muted,
                    .selection_color = t.primary.withAlpha(0.3),
                    .cursor_color = t.text,
                    .on_blur_handler = cx.update(FormState, FormState.onConfirmPasswordBlur),
                }),
                // Error text (always 16px tall)
                ui.box(.{ .height = 16 }, .{confirm_helper}),
            }),
        }));
    }
};

const FormActions = struct {
    is_valid: bool,
    submitted: bool,

    pub fn render(self: FormActions, cx: *Cx) void {
        const s = cx.state(FormState);
        const t = cx.theme();

        if (s.pending_focus) |field_id| {
            cx.focusTextField(field_id);
            s.pending_focus = null;
        }

        cx.render(ui.box(.{
            .direction = .row,
            .gap = 12,
            .padding = .{ .each = .{ .top = 8, .right = 0, .bottom = 0, .left = 0 } },
            .alignment = .{ .cross = .center },
        }, .{
            Button{
                .id = "submit",
                .label = "Submit",
                .variant = .primary,
                .on_click_handler = cx.update(FormState, FormState.submit),
            },
            Button{
                .id = "reset",
                .label = "Reset",
                .variant = .secondary,
                .on_click_handler = cx.update(FormState, FormState.reset),
            },
            ui.box(.{ .grow = true }, .{}),
            ui.when(self.submitted and !self.is_valid, .{
                ui.text("Please fix the errors above", .{ .size = 14, .color = t.danger }),
            }),
        }));
    }
};

const DebugPanel = struct {
    username: []const u8,
    email: []const u8,
    is_valid: bool,
    touched: FormState.TouchedFields,

    pub fn render(self: DebugPanel, cx: *Cx) void {
        const t = cx.theme();

        cx.render(ui.box(.{
            .direction = .column,
            .gap = 6,
            .padding = .{ .all = 12 },
            .background = t.overlay,
            .corner_radius = t.radius_sm,
        }, .{
            ui.text("Debug Info:", .{ .size = 12, .weight = .semibold, .color = t.muted }),
            DebugRow{ .label = "Username", .value = if (self.username.len > 0) self.username else "(empty)" },
            DebugRow{ .label = "Email", .value = if (self.email.len > 0) self.email else "(empty)" },
            DebugRow{ .label = "Form Valid", .value = if (self.is_valid) "Yes" else "No" },
            DebugRow{
                .label = "Touched",
                .value = if (self.touched.anyTouched()) "Some fields touched" else "No fields touched",
            },
        }));
    }
};

const DebugRow = struct {
    label: []const u8,
    value: []const u8,

    pub fn render(self: DebugRow, cx: *Cx) void {
        const t = cx.theme();

        cx.render(ui.box(.{ .direction = .row, .gap = 8 }, .{
            ui.text(self.label, .{ .size = 11, .color = t.muted }),
            ui.text(self.value, .{ .size = 11, .color = t.subtext }),
        }));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "validation functions" {
    const testing = std.testing;

    var s = FormState{};

    try testing.expect(s.validateUsername() != null);
    try testing.expect(s.validateEmail() != null);
    try testing.expect(s.validatePassword() != null);

    s.username = "john123";
    try testing.expect(s.validateUsername() == null);

    s.username = "ab";
    try testing.expect(s.validateUsername() != null);

    s.username = "john_doe";
    try testing.expect(s.validateUsername() != null);

    s.email = "test@example.com";
    try testing.expect(s.validateEmail() == null);

    s.email = "notanemail";
    try testing.expect(s.validateEmail() != null);

    s.password = "password123";
    try testing.expect(s.validatePassword() == null);

    s.password = "short";
    try testing.expect(s.validatePassword() != null);
}

test "password confirmation" {
    const testing = std.testing;

    var s = FormState{};
    s.password = "mypassword";
    s.confirm_password = "mypassword";
    try testing.expect(s.validateConfirmPassword() == null);

    s.confirm_password = "different";
    try testing.expect(s.validateConfirmPassword() != null);
}

test "form validity" {
    const testing = std.testing;

    var s = FormState{};
    try testing.expect(!s.isFormValid());

    s.username = "validuser";
    s.email = "user@example.com";
    s.password = "securepass";
    s.confirm_password = "securepass";
    try testing.expect(s.isFormValid());
}

test "touched state" {
    const testing = std.testing;

    var s = FormState{};
    try testing.expect(!s.touched.username);
    try testing.expect(!s.touched.email);

    s.onUsernameBlur();
    try testing.expect(s.touched.username);
    try testing.expect(!s.touched.email);

    s.touched.touchAll();
    try testing.expect(s.touched.username);
    try testing.expect(s.touched.email);
    try testing.expect(s.touched.password);
    try testing.expect(s.touched.confirm_password);

    s.touched.reset();
    try testing.expect(!s.touched.username);
}

test "form reset" {
    const testing = std.testing;

    var s = FormState{};
    s.username = "test";
    s.email = "test@test.com";
    s.touched.touchAll();
    s.submitted = true;
    s.show_success = true;

    s.reset();

    try testing.expectEqualStrings("", s.username);
    try testing.expectEqualStrings("", s.email);
    try testing.expect(!s.touched.username);
    try testing.expect(!s.submitted);
    try testing.expect(!s.show_success);
}
