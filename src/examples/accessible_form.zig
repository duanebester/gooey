//! Accessible Form Example
//!
//! Demonstrates comprehensive accessibility patterns in Gooey:
//! - Form structure with proper headings and groups
//! - Text inputs with accessible labels
//! - Checkboxes and radio buttons
//! - Select dropdowns
//! - Form validation with live region announcements
//! - Error states and feedback
//! - Keyboard navigation
//!
//! To test accessibility:
//! - macOS: Enable VoiceOver with Cmd+F5
//! - Linux: Enable Orca with Super+Alt+S
//! - Web: Use browser accessibility tools or NVDA/VoiceOver
//!
//! Navigate with Tab, activate with Space/Enter, use arrow keys in groups.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const Checkbox = gooey.Checkbox;
const TextInput = gooey.TextInput;
const Select = gooey.Select;

// =============================================================================
// Form State
// =============================================================================

const FormState = struct {
    // Personal info
    name: []const u8 = "",
    email: []const u8 = "",
    phone: []const u8 = "",

    // Preferences
    contact_method: ContactMethod = .email,
    newsletter: bool = true,
    terms_accepted: bool = false,

    // Experience level selection
    experience_select_open: bool = false,
    experience_level: ?usize = null,

    // Form status
    form_submitted: bool = false,
    validation_errors: ValidationErrors = .{},
    last_validation_message: []const u8 = "",
    show_success: bool = false,

    pub const ContactMethod = enum {
        email,
        phone,
        mail,

        pub fn label(self: ContactMethod) []const u8 {
            return switch (self) {
                .email => "Email",
                .phone => "Phone",
                .mail => "Postal Mail",
            };
        }
    };

    pub const ValidationErrors = struct {
        name: bool = false,
        email: bool = false,
        terms: bool = false,
    };

    // Experience level options
    pub const experience_options = [_][]const u8{
        "Beginner",
        "Intermediate",
        "Advanced",
        "Expert",
    };

    // Actions
    pub fn toggleNewsletter(self: *FormState) void {
        self.newsletter = !self.newsletter;
    }

    pub fn toggleTerms(self: *FormState) void {
        self.terms_accepted = !self.terms_accepted;
        if (self.terms_accepted) {
            self.validation_errors.terms = false;
        }
    }

    pub fn setContactEmail(self: *FormState) void {
        self.contact_method = .email;
    }

    pub fn setContactPhone(self: *FormState) void {
        self.contact_method = .phone;
    }

    pub fn setContactMail(self: *FormState) void {
        self.contact_method = .mail;
    }

    pub fn toggleExperienceSelect(self: *FormState) void {
        self.experience_select_open = !self.experience_select_open;
    }

    pub fn closeExperienceSelect(self: *FormState) void {
        self.experience_select_open = false;
    }

    pub fn selectExperience0(self: *FormState) void {
        self.experience_level = 0;
        self.experience_select_open = false;
    }

    pub fn selectExperience1(self: *FormState) void {
        self.experience_level = 1;
        self.experience_select_open = false;
    }

    pub fn selectExperience2(self: *FormState) void {
        self.experience_level = 2;
        self.experience_select_open = false;
    }

    pub fn selectExperience3(self: *FormState) void {
        self.experience_level = 3;
        self.experience_select_open = false;
    }

    pub fn validate(self: *FormState) bool {
        var valid = true;

        // Check name
        if (self.name.len == 0) {
            self.validation_errors.name = true;
            valid = false;
        } else {
            self.validation_errors.name = false;
        }

        // Check email (simple validation)
        if (self.email.len == 0 or std.mem.indexOf(u8, self.email, "@") == null) {
            self.validation_errors.email = true;
            valid = false;
        } else {
            self.validation_errors.email = false;
        }

        // Check terms
        if (!self.terms_accepted) {
            self.validation_errors.terms = true;
            valid = false;
        } else {
            self.validation_errors.terms = false;
        }

        if (!valid) {
            self.last_validation_message = "Please fix the errors in the form";
        }

        return valid;
    }

    pub fn submit(self: *FormState) void {
        if (self.validate()) {
            self.form_submitted = true;
            self.show_success = true;
            self.last_validation_message = "Form submitted successfully!";
        }
    }

    pub fn reset(self: *FormState) void {
        self.* = FormState{};
    }

    pub fn dismissSuccess(self: *FormState) void {
        self.show_success = false;
        self.reset();
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = FormState{};

const App = gooey.App(FormState, &state, render, .{
    .title = "Accessible Form Example",
    .width = 600,
    .height = 800,
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
    const b = cx.builder();
    const g = b.gooey orelse return;

    // Announce validation errors assertively
    if (s.last_validation_message.len > 0) {
        if (std.mem.indexOf(u8, s.last_validation_message, "error") != null or
            std.mem.indexOf(u8, s.last_validation_message, "fix") != null)
        {
            g.announce(s.last_validation_message, .assertive);
        } else {
            g.announce(s.last_validation_message, .polite);
        }
        // Clear after announcing
        s.last_validation_message = "";
    }

    // Use scroll container for form content
    cx.render(ui.scroll("form-scroll", .{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .gap = 24,
        .background = ui.Color.rgb(0.96, 0.96, 0.98),
        .content_height = 1200, // Approximate content height
    }, .{
        // Header
        FormHeader{},

        // A11y status indicator
        A11yStatus{},

        // Show success message or form
        ui.when(s.show_success, .{
            SuccessMessage{},
        }),

        ui.when(!s.show_success, .{
            // Personal Information Section
            PersonalInfoSection{
                .name = s.name,
                .email = s.email,
                .phone = s.phone,
                .errors = s.validation_errors,
            },
            // Contact Preferences Section
            ContactPreferencesSection{
                .contact_method = s.contact_method,
                .newsletter = s.newsletter,
            },
            // Experience Level Section
            ExperienceSection{
                .experience_level = s.experience_level,
                .select_open = s.experience_select_open,
            },
            // Terms and Submit Section
            TermsSection{
                .terms_accepted = s.terms_accepted,
                .has_error = s.validation_errors.terms,
            },
            // Form Actions
            FormActions{},
        }),
    }));
}

// =============================================================================
// Header Components
// =============================================================================

const FormHeader = struct {
    pub fn render(_: FormHeader, cx: *Cx) void {
        const b = cx.builder();

        // Main page heading (h1)
        if (b.accessible(.{
            .role = .heading,
            .name = "Registration Form",
            .heading_level = .h1,
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.vstack(.{ .gap = 8 }, .{
            ui.text("Registration Form", .{
                .size = 32,
                .weight = .bold,
                .color = ui.Color.rgb(0.1, 0.1, 0.2),
            }),
            ui.text("Please fill out all required fields marked with *", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
        }));
    }
};

const A11yStatus = struct {
    pub fn render(_: A11yStatus, cx: *Cx) void {
        const b = cx.builder();
        const g = b.gooey orelse return;
        const is_enabled = g.isA11yEnabled();

        const status_text = if (is_enabled)
            "Screen reader detected - accessibility features active"
        else
            "No screen reader detected";

        // Accessible status region
        if (b.accessible(.{
            .role = .status,
            .name = status_text,
            .live = .polite,
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            ui.box(.{
                .width = 10,
                .height = 10,
                .corner_radius = 5,
                .background = if (is_enabled)
                    ui.Color.rgb(0.2, 0.7, 0.3)
                else
                    ui.Color.rgb(0.6, 0.6, 0.6),
            }, .{}),
            ui.text(
                if (is_enabled) "Accessibility Active" else "Standard Mode",
                .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.5) },
            ),
        }));
    }
};

// =============================================================================
// Form Sections
// =============================================================================

const PersonalInfoSection = struct {
    name: []const u8,
    email: []const u8,
    phone: []const u8,
    errors: FormState.ValidationErrors,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(FormState);
        const b = cx.builder();

        // Section heading (h2)
        if (b.accessible(.{
            .role = .heading,
            .name = "Personal Information",
            .heading_level = .h2,
        })) {
            defer b.accessibleEnd();
        }

        // Group for form fields
        if (b.accessible(.{
            .role = .group,
            .name = "Personal information fields",
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.box(.{
            .padding = .{ .all = 20 },
            .gap = 16,
            .background = ui.Color.white,
            .corner_radius = 12,
            .border_color = ui.Color.rgb(0.9, 0.9, 0.9),
            .border_width = .{ .all = 1 },
        }, .{
            ui.text("Personal Information", .{
                .size = 18,
                .weight = .semibold,
                .color = ui.Color.rgb(0.2, 0.2, 0.3),
            }),

            // Name field
            FormField{
                .label = "Full Name *",
                .error_message = if (self.errors.name) "Name is required" else null,
            },
            TextInput{
                .id = "name",
                .placeholder = "Enter your full name",
                .accessible_name = "Full name, required field",
                .accessible_description = if (self.errors.name) "Error: Name is required" else null,
                .bind = @constCast(&s.name),
                .width = 300,
                .border_color = if (self.errors.name)
                    ui.Color.rgb(0.9, 0.3, 0.3)
                else
                    null,
            },

            // Email field
            FormField{
                .label = "Email Address *",
                .error_message = if (self.errors.email) "Valid email is required" else null,
            },
            TextInput{
                .id = "email",
                .placeholder = "name@example.com",
                .accessible_name = "Email address, required field",
                .accessible_description = if (self.errors.email) "Error: Please enter a valid email address" else null,
                .bind = @constCast(&s.email),
                .width = 300,
                .border_color = if (self.errors.email)
                    ui.Color.rgb(0.9, 0.3, 0.3)
                else
                    null,
            },

            // Phone field (optional)
            FormField{
                .label = "Phone Number",
                .error_message = null,
            },
            TextInput{
                .id = "phone",
                .placeholder = "(555) 123-4567",
                .accessible_name = "Phone number, optional field",
                .bind = @constCast(&s.phone),
                .width = 300,
            },
        }));
    }
};

const ContactPreferencesSection = struct {
    contact_method: FormState.ContactMethod,
    newsletter: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Section heading (h2)
        if (b.accessible(.{
            .role = .heading,
            .name = "Contact Preferences",
            .heading_level = .h2,
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.box(.{
            .padding = .{ .all = 20 },
            .gap = 16,
            .background = ui.Color.white,
            .corner_radius = 12,
            .border_color = ui.Color.rgb(0.9, 0.9, 0.9),
            .border_width = .{ .all = 1 },
        }, .{
            ui.text("Contact Preferences", .{
                .size = 18,
                .weight = .semibold,
                .color = ui.Color.rgb(0.2, 0.2, 0.3),
            }),

            // Radio group for contact method
            RadioGroupSection{
                .label = "Preferred Contact Method",
                .contact_method = self.contact_method,
            },

            // Newsletter checkbox
            ui.spacerMin(8),
            Checkbox{
                .id = "newsletter",
                .checked = self.newsletter,
                .label = "Subscribe to our newsletter",
                .accessible_name = "Subscribe to newsletter",
                .accessible_description = "Receive weekly updates about our products and services",
                .on_click_handler = cx.update(FormState, FormState.toggleNewsletter),
            },
        }));
    }
};

const RadioGroupSection = struct {
    label: []const u8,
    contact_method: FormState.ContactMethod,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Radiogroup container
        if (b.accessible(.{
            .role = .group, // radiogroup maps to group
            .name = self.label,
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.vstack(.{ .gap = 12 }, .{
            ui.text(self.label, .{
                .size = 14,
                .weight = .medium,
                .color = ui.Color.rgb(0.3, 0.3, 0.4),
            }),

            ui.vstack(.{ .gap = 8 }, .{
                RadioOption{
                    .label = "Email",
                    .selected = self.contact_method == .email,
                    .pos_in_set = 1,
                    .set_size = 3,
                    .on_select = cx.update(FormState, FormState.setContactEmail),
                },
                RadioOption{
                    .label = "Phone",
                    .selected = self.contact_method == .phone,
                    .pos_in_set = 2,
                    .set_size = 3,
                    .on_select = cx.update(FormState, FormState.setContactPhone),
                },
                RadioOption{
                    .label = "Postal Mail",
                    .selected = self.contact_method == .mail,
                    .pos_in_set = 3,
                    .set_size = 3,
                    .on_select = cx.update(FormState, FormState.setContactMail),
                },
            }),
        }));
    }
};

const RadioOption = struct {
    label: []const u8,
    selected: bool,
    pos_in_set: u16,
    set_size: u16,
    on_select: ui.HandlerRef,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Accessible radio button
        if (b.accessible(.{
            .role = .radio,
            .name = self.label,
            .state = .{
                .checked = self.selected,
            },
            .pos_in_set = self.pos_in_set,
            .set_size = self.set_size,
        })) {
            defer b.accessibleEnd();
        }

        // Wrap in clickable box
        cx.render(ui.box(.{
            .direction = .row,
            .gap = 8,
            .alignment = .{ .cross = .center },
            .on_click_handler = self.on_select,
        }, .{
            // Radio circle
            ui.box(.{
                .width = 18,
                .height = 18,
                .corner_radius = 9,
                .border_color = if (self.selected)
                    ui.Color.rgb(0.2, 0.5, 0.9)
                else
                    ui.Color.rgb(0.7, 0.7, 0.7),
                .border_width = .{ .all = 2 },
                .background = ui.Color.white,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                // Inner dot when selected
                ui.when(self.selected, .{
                    ui.box(.{
                        .width = 10,
                        .height = 10,
                        .corner_radius = 5,
                        .background = ui.Color.rgb(0.2, 0.5, 0.9),
                    }, .{}),
                }),
            }),
            ui.text(self.label, .{
                .size = 14,
                .color = ui.Color.rgb(0.2, 0.2, 0.3),
            }),
        }));
    }
};

const ExperienceSection = struct {
    experience_level: ?usize,
    select_open: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Section heading (h2)
        if (b.accessible(.{
            .role = .heading,
            .name = "Experience Level",
            .heading_level = .h2,
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.box(.{
            .padding = .{ .all = 20 },
            .gap = 16,
            .background = ui.Color.white,
            .corner_radius = 12,
            .border_color = ui.Color.rgb(0.9, 0.9, 0.9),
            .border_width = .{ .all = 1 },
        }, .{
            ui.text("Experience Level", .{
                .size = 18,
                .weight = .semibold,
                .color = ui.Color.rgb(0.2, 0.2, 0.3),
            }),

            FormField{
                .label = "Your experience with our products",
                .error_message = null,
            },

            Select{
                .id = "experience",
                .options = &FormState.experience_options,
                .selected = self.experience_level,
                .placeholder = "Select your experience level",
                .is_open = self.select_open,
                .on_toggle_handler = cx.update(FormState, FormState.toggleExperienceSelect),
                .on_close_handler = cx.update(FormState, FormState.closeExperienceSelect),
                .handlers = &.{
                    cx.update(FormState, FormState.selectExperience0),
                    cx.update(FormState, FormState.selectExperience1),
                    cx.update(FormState, FormState.selectExperience2),
                    cx.update(FormState, FormState.selectExperience3),
                },
                .accessible_name = "Experience level",
                .accessible_description = "Select how experienced you are with our products",
            },
        }));
    }
};

const TermsSection = struct {
    terms_accepted: bool,
    has_error: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Group for terms
        if (b.accessible(.{
            .role = .group,
            .name = "Terms and conditions agreement",
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.box(.{
            .padding = .{ .all = 20 },
            .gap = 12,
            .background = if (self.has_error)
                ui.Color.rgb(1.0, 0.95, 0.95)
            else
                ui.Color.white,
            .corner_radius = 12,
            .border_color = if (self.has_error)
                ui.Color.rgb(0.9, 0.3, 0.3)
            else
                ui.Color.rgb(0.9, 0.9, 0.9),
            .border_width = .{ .all = 1 },
        }, .{
            Checkbox{
                .id = "terms",
                .checked = self.terms_accepted,
                .label = "I accept the Terms and Conditions *",
                .accessible_name = "Accept terms and conditions, required",
                .accessible_description = if (self.has_error)
                    "Error: You must accept the terms to continue"
                else
                    "Required to submit the form",
                .on_click_handler = cx.update(FormState, FormState.toggleTerms),
            },

            ui.when(self.has_error, .{
                ErrorMessage{
                    .message = "You must accept the terms and conditions to continue",
                },
            }),
        }));
    }
};

const FormActions = struct {
    pub fn render(_: FormActions, cx: *Cx) void {
        const b = cx.builder();

        // Group for form actions
        if (b.accessible(.{
            .role = .group,
            .name = "Form actions",
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.hstack(.{ .gap = 16 }, .{
            Button{
                .label = "Submit",
                .accessible_name = "Submit registration form",
                .variant = .primary,
                .size = .large,
                .on_click_handler = cx.update(FormState, FormState.submit),
            },

            Button{
                .label = "Reset",
                .accessible_name = "Reset form to default values",
                .variant = .secondary,
                .size = .large,
                .on_click_handler = cx.update(FormState, FormState.reset),
            },
        }));
    }
};

// =============================================================================
// Helper Components
// =============================================================================

const FormField = struct {
    label: []const u8,
    error_message: ?[]const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.vstack(.{ .gap = 4 }, .{
            ui.text(self.label, .{
                .size = 14,
                .weight = .medium,
                .color = if (self.error_message != null)
                    ui.Color.rgb(0.9, 0.3, 0.3)
                else
                    ui.Color.rgb(0.3, 0.3, 0.4),
            }),
            ui.when(self.error_message != null, .{
                ErrorMessage{ .message = self.error_message orelse "" },
            }),
        }));
    }
};

const ErrorMessage = struct {
    message: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Accessible error alert
        if (b.accessible(.{
            .role = .alert,
            .name = self.message,
            .live = .assertive,
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.hstack(.{ .gap = 4, .alignment = .center }, .{
            ui.text("⚠", .{
                .size = 12,
                .color = ui.Color.rgb(0.9, 0.3, 0.3),
            }),
            ui.text(self.message, .{
                .size = 12,
                .color = ui.Color.rgb(0.9, 0.3, 0.3),
            }),
        }));
    }
};

const SuccessMessage = struct {
    pub fn render(_: SuccessMessage, cx: *Cx) void {
        const b = cx.builder();

        // Accessible success alert
        if (b.accessible(.{
            .role = .alert,
            .name = "Registration successful! Thank you for signing up.",
            .live = .assertive,
        })) {
            defer b.accessibleEnd();
        }

        cx.render(ui.box(.{
            .padding = .{ .all = 32 },
            .gap = 20,
            .background = ui.Color.rgb(0.9, 1.0, 0.9),
            .corner_radius = 12,
            .border_color = ui.Color.rgb(0.2, 0.7, 0.3),
            .border_width = .{ .all = 2 },
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("✓", .{
                .size = 48,
                .color = ui.Color.rgb(0.2, 0.7, 0.3),
            }),
            ui.text("Registration Successful!", .{
                .size = 24,
                .weight = .bold,
                .color = ui.Color.rgb(0.2, 0.5, 0.3),
            }),
            ui.text("Thank you for signing up. We'll be in touch soon.", .{
                .size = 16,
                .color = ui.Color.rgb(0.3, 0.5, 0.4),
            }),
            ui.spacerMin(12),
            Button{
                .label = "Submit Another Response",
                .accessible_name = "Start a new registration",
                .variant = .primary,
                .on_click_handler = cx.update(FormState, FormState.dismissSuccess),
            },
        }));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "form validation" {
    var s = FormState{};

    // Empty form should fail validation
    try std.testing.expect(!s.validate());
    try std.testing.expect(s.validation_errors.name);
    try std.testing.expect(s.validation_errors.email);
    try std.testing.expect(s.validation_errors.terms);

    // Valid form should pass
    s.name = "John Doe";
    s.email = "john@example.com";
    s.terms_accepted = true;

    try std.testing.expect(s.validate());
    try std.testing.expect(!s.validation_errors.name);
    try std.testing.expect(!s.validation_errors.email);
    try std.testing.expect(!s.validation_errors.terms);
}

test "form state toggles" {
    var s = FormState{};

    // Newsletter toggle
    try std.testing.expect(s.newsletter);
    s.toggleNewsletter();
    try std.testing.expect(!s.newsletter);

    // Terms toggle
    try std.testing.expect(!s.terms_accepted);
    s.toggleTerms();
    try std.testing.expect(s.terms_accepted);

    // Contact method
    try std.testing.expectEqual(FormState.ContactMethod.email, s.contact_method);
    s.setContactPhone();
    try std.testing.expectEqual(FormState.ContactMethod.phone, s.contact_method);
}

test "form reset" {
    var s = FormState{};
    s.name = "Test";
    s.email = "test@test.com";
    s.newsletter = false;
    s.terms_accepted = true;
    s.form_submitted = true;

    s.reset();

    try std.testing.expectEqualStrings("", s.name);
    try std.testing.expectEqualStrings("", s.email);
    try std.testing.expect(s.newsletter);
    try std.testing.expect(!s.terms_accepted);
    try std.testing.expect(!s.form_submitted);
}
