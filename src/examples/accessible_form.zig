//! Accessible form: accessibility patterns on the core.
//!
//! Headings, groups, labelled inputs, a radio group with set positions, a
//! checkbox, a combobox `Select`, live-region error alerts, and
//! announcements from the submit handler. Every accessible element is a box
//! whose `a11y` names its role, so a screen reader also gets its bounds.
//!
//! To test accessibility:
//! - macOS: Enable VoiceOver with Cmd+F5
//! - Web: Use browser accessibility tools or NVDA/VoiceOver
//!
//! Navigate with Tab and type into the focused field.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Effects = core.Effects;
const Handler = core.Handler;
const Button = components.core.Button;
const Checkbox = components.core.Checkbox;
const TextInput = components.core.TextInput;
const Select = components.core.Select;

// =============================================================================
// Form State
// =============================================================================

pub const State = struct {
    // Personal info, bound to the text inputs.
    name: []const u8 = "",
    email: []const u8 = "",
    phone: []const u8 = "",

    // Preferences.
    contact_method: ContactMethod = .email,
    newsletter: bool = true,
    terms_accepted: bool = false,

    // Experience level selection.
    experience_level: ?usize = null,
    experience_open: bool = false,

    // Form status.
    form_submitted: bool = false,
    validation_errors: ValidationErrors = .{},
    show_success: bool = false,

    pub const ContactMethod = enum { email, phone, mail };

    pub const ValidationErrors = struct {
        name: bool = false,
        email: bool = false,
        terms: bool = false,
    };

    pub const experience_options = [_][]const u8{
        "Beginner",
        "Intermediate",
        "Advanced",
        "Expert",
    };

    pub fn toggleNewsletter(self: *State) void {
        self.newsletter = !self.newsletter;
    }

    pub fn toggleTerms(self: *State) void {
        self.terms_accepted = !self.terms_accepted;
        if (self.terms_accepted) self.validation_errors.terms = false;
    }

    pub fn setContact(self: *State, method: ContactMethod) void {
        self.contact_method = method;
        assert(self.contact_method == method);
    }

    pub fn selectExperience(self: *State, index: u32) void {
        assert(index < experience_options.len);
        self.experience_level = index;
        self.experience_open = false;
        assert(self.experience_level.? == index);
    }

    pub fn toggleExperience(self: *State) void {
        const was_open = self.experience_open;
        self.experience_open = !self.experience_open;
        assert(self.experience_open != was_open);
    }

    pub fn closeExperience(self: *State) void {
        self.experience_open = false;
        assert(!self.experience_open);
    }

    pub fn validate(self: *State) bool {
        self.validation_errors = .{
            .name = self.name.len == 0,
            .email = self.email.len == 0 or std.mem.indexOf(u8, self.email, "@") == null,
            .terms = !self.terms_accepted,
        };
        const errors = self.validation_errors;
        return !errors.name and !errors.email and !errors.terms;
    }

    /// Announces the outcome: errors assertively, success politely.
    pub fn submit(self: *State, effects: *Effects) void {
        if (self.validate()) {
            self.form_submitted = true;
            self.show_success = true;
            effects.announce("Form submitted successfully!", .polite);
        } else {
            effects.announce("Please fix the errors in the form", .assertive);
        }
    }

    pub fn reset(self: *State) void {
        self.* = State{};
    }

    pub fn dismissSuccess(self: *State) void {
        self.reset();
        assert(!self.show_success);
    }
};

const assert = std.debug.assert;

// =============================================================================
// Entry Point
// =============================================================================

pub const App = core.App(State, render, .{
    .title = "Accessible Form Example",
    .width = 600,
    .height = 800,
    .limits = .small,
});

/// The generated entry point (contract §7).
pub const main = App.main;

// =============================================================================
// Main Render
// =============================================================================

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{
        .key = .{ .name = "form-scroll" },
        .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .all(32),
            .gap = 24,
            .background = .{ .rgba = ui.Color.rgb(0.96, 0.96, 0.98) },
            .scroll = .{},
        },
    }, .{
        FormHeader{},
        if (s.show_success) SuccessMessage{} else null,
        if (s.show_success) null else FormBody{},
    }));
}

const FormBody = struct {
    pub fn render(_: FormBody, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{ .style = .{ .gap = 24 } }, .{
            PersonalInfoSection{ .errors = s.validation_errors },
            ContactPreferencesSection{
                .contact_method = s.contact_method,
                .newsletter = s.newsletter,
            },
            ExperienceSection{
                .experience_level = s.experience_level,
                .experience_open = s.experience_open,
            },
            TermsSection{
                .terms_accepted = s.terms_accepted,
                .has_error = s.validation_errors.terms,
            },
            FormActions{},
        }));
    }
};

// =============================================================================
// Shared Pieces
// =============================================================================

const error_color = ui.Color.rgb(0.9, 0.3, 0.3);
const title_color = ui.Color.rgb(0.2, 0.2, 0.3);
const label_color = ui.Color.rgb(0.3, 0.3, 0.4);

/// A white card. `group` names it for screen readers.
fn card(group: ?[]const u8, has_error: bool) ui.Box {
    return .{
        .style = .{
            .padding = .all(20),
            .gap = 16,
            .background = .{
                .rgba = if (has_error) ui.Color.rgb(1, 0.95, 0.95) else ui.Color.white,
            },
            .corner_radius = .all(12),
            .border = .{
                .width = 1,
                .color = .{ .rgba = if (has_error) error_color else ui.Color.rgb(0.9, 0.9, 0.9) },
            },
        },
        .a11y = if (group) |name| .{ .role = .group, .label = name } else null,
    };
}

/// A heading box, so the screen reader reads it at its level and place.
const Heading = struct {
    text: []const u8,
    level: @FieldType(ui.A11y, "heading_level"),
    size: u16,
    weight: @FieldType(ui.Text, "weight"),
    color: ui.Color,

    pub fn render(self: Heading, cx: *Cx) void {
        cx.render(ui.box(.{
            .a11y = .{ .role = .heading, .label = self.text, .heading_level = self.level },
        }, .{
            ui.text(self.text, .{
                .size = self.size,
                .weight = self.weight,
                .color = .{ .rgba = self.color },
            }),
        }));
    }
};

fn sectionHeading(text: []const u8) Heading {
    return .{ .text = text, .level = .h2, .size = 18, .weight = .semibold, .color = title_color };
}

// =============================================================================
// Header
// =============================================================================

const FormHeader = struct {
    pub fn render(_: FormHeader, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{ .gap = 8 } }, .{
            Heading{
                .text = "Registration Form",
                .level = .h1,
                .size = 32,
                .weight = .bold,
                .color = ui.Color.rgb(0.1, 0.1, 0.2),
            },
            ui.text("Please fill out all required fields marked with *", .{
                .size = 14,
                .color = .{ .rgba = ui.Color.rgb(0.5, 0.5, 0.5) },
            }),
        }));
    }
};

// =============================================================================
// Form Sections
// =============================================================================

const PersonalInfoSection = struct {
    errors: State.ValidationErrors,

    pub fn render(self: PersonalInfoSection, cx: *Cx) void {
        const s = cx.state(State);
        const errors = self.errors;
        cx.render(ui.box(card("Personal information fields", false), .{
            sectionHeading("Personal Information"),
            FormField{
                .label = "Full Name *",
                .error_message = if (errors.name) "Name is required" else null,
            },
            TextInput{
                .key = "name",
                .bind = &s.name,
                .placeholder = "Enter your full name",
                .accessible_name = "Full name, required field",
                .accessible_description = if (errors.name) "Error: Name is required" else null,
                .width = 300,
                .border_color = if (errors.name) error_color else null,
            },
            FormField{
                .label = "Email Address *",
                .error_message = if (errors.email) "Valid email is required" else null,
            },
            TextInput{
                .key = "email",
                .bind = &s.email,
                .placeholder = "name@example.com",
                .accessible_name = "Email address, required field",
                .accessible_description = if (errors.email)
                    "Error: Please enter a valid email address"
                else
                    null,
                .width = 300,
                .border_color = if (errors.email) error_color else null,
            },
            FormField{ .label = "Phone Number", .error_message = null },
            TextInput{
                .key = "phone",
                .bind = &s.phone,
                .placeholder = "(555) 123-4567",
                .accessible_name = "Phone number, optional field",
                .width = 300,
            },
        }));
    }
};

const ContactPreferencesSection = struct {
    contact_method: State.ContactMethod,
    newsletter: bool,

    pub fn render(self: ContactPreferencesSection, cx: *Cx) void {
        cx.render(ui.box(card(null, false), .{
            sectionHeading("Contact Preferences"),
            RadioGroup{ .label = "Preferred Contact Method", .selected = self.contact_method },
            // 0.3.1's `ui.spacerMin(8)`: the newsletter sits apart from the radios.
            ui.box(.{ .style = .{ .height = .{ .fixed = 8 } } }, .{}),
            Checkbox{
                .key = .{ .name = "newsletter" },
                .checked = self.newsletter,
                .label = "Subscribe to our newsletter",
                .accessible_name = "Subscribe to newsletter",
                .accessible_description = "Receive weekly updates about our products and services",
                .on_click = cx.on(State.toggleNewsletter, .{}),
            },
        }));
    }
};

const RadioGroup = struct {
    label: []const u8,
    selected: State.ContactMethod,

    const labels = [_][]const u8{ "Email", "Phone", "Postal Mail" };

    pub fn render(self: RadioGroup, cx: *Cx) void {
        // A radio group maps to a group role, as in 0.3.1.
        cx.render(ui.box(.{
            .style = .{ .gap = 12, .padding = .{ .top = 8 } },
            .a11y = .{ .role = .group, .label = self.label },
        }, .{
            ui.text(self.label, .{
                .size = 14,
                .weight = .medium,
                .color = .{ .rgba = label_color },
            }),
            ui.box(.{ .style = .{ .gap = 8 } }, .{RadioOptions{ .selected = self.selected }}),
        }));
    }
};

const RadioOptions = struct {
    selected: State.ContactMethod,

    pub fn render(self: RadioOptions, cx: *Cx) void {
        const methods = std.enums.values(State.ContactMethod);
        assert(methods.len == RadioGroup.labels.len);
        for (methods, 0..) |method, index| {
            cx.render(RadioOption{
                .label = RadioGroup.labels[index],
                .selected = self.selected == method,
                .pos_in_set = @intCast(index + 1),
                .set_size = @intCast(methods.len),
                .on_select = cx.on(State.setContact, .{ .arg = method }),
            });
        }
    }
};

const RadioOption = struct {
    label: []const u8,
    selected: bool,
    pos_in_set: u16,
    set_size: u16,
    on_select: Handler,

    const accent = ui.Color.rgb(0.2, 0.5, 0.9);
    const unselected = ui.Color.rgb(0.7, 0.7, 0.7);

    pub fn render(self: RadioOption, cx: *Cx) void {
        assert(self.pos_in_set >= 1);
        assert(self.pos_in_set <= self.set_size);
        cx.render(ui.box(.{
            .key = .{ .name = self.label },
            .style = .{ .direction = .row, .gap = 8, .alignment = .center_cross },
            .on_click = self.on_select,
            .a11y = .{
                .role = .radio,
                .label = self.label,
                .checked = self.selected,
                .pos_in_set = self.pos_in_set,
                .set_size = self.set_size,
            },
        }, .{
            ui.box(.{ .style = .{
                .width = .{ .fixed = 18 },
                .height = .{ .fixed = 18 },
                .corner_radius = .all(9),
                .border = .{
                    .width = 2,
                    .color = .{ .rgba = if (self.selected) accent else unselected },
                },
                .background = .{ .rgba = ui.Color.white },
                .alignment = .center,
            } }, .{
                if (self.selected) ui.box(.{ .style = .{
                    .width = .{ .fixed = 10 },
                    .height = .{ .fixed = 10 },
                    .corner_radius = .all(5),
                    .background = .{ .rgba = accent },
                } }, .{}) else null,
            }),
            ui.text(self.label, .{ .size = 14, .color = .{ .rgba = title_color } }),
        }));
    }
};

const ExperienceSection = struct {
    experience_level: ?usize,
    experience_open: bool,

    pub fn render(self: ExperienceSection, cx: *Cx) void {
        var on_select: [State.experience_options.len]Handler = undefined;
        for (&on_select, 0..) |*handler, index| {
            handler.* = cx.on(State.selectExperience, .{ .arg = @as(u32, @intCast(index)) });
        }
        cx.render(ui.box(card(null, false), .{
            sectionHeading("Experience Level"),
            FormField{ .label = "Your experience with our products", .error_message = null },
            Select{
                .key = "experience",
                .options = &State.experience_options,
                .on_select = &on_select,
                .on_toggle = cx.on(State.toggleExperience, .{}),
                .on_close = cx.on(State.closeExperience, .{}),
                .selected = self.experience_level,
                .open = self.experience_open,
                .placeholder = "Select your experience level",
                .accessible_name = "Experience level",
                .accessible_description = "Select how experienced you are with our products",
            },
        }));
    }
};

const TermsSection = struct {
    terms_accepted: bool,
    has_error: bool,

    pub fn render(self: TermsSection, cx: *Cx) void {
        var box = card("Terms and conditions agreement", self.has_error);
        box.style.gap = 12;
        cx.render(ui.box(box, .{
            Checkbox{
                .key = .{ .name = "terms" },
                .checked = self.terms_accepted,
                .label = "I accept the Terms and Conditions *",
                .accessible_name = "Accept terms and conditions, required",
                .accessible_description = if (self.has_error)
                    "Error: You must accept the terms to continue"
                else
                    "Required to submit the form",
                .on_click = cx.on(State.toggleTerms, .{}),
            },
            if (self.has_error) ErrorMessage{
                .message = "You must accept the terms and conditions to continue",
            } else null,
        }));
    }
};

const FormActions = struct {
    pub fn render(_: FormActions, cx: *Cx) void {
        cx.render(ui.box(.{
            .style = .{ .direction = .row, .gap = 16 },
            .a11y = .{ .role = .group, .label = "Form actions" },
        }, .{
            Button{
                .label = "Submit",
                .accessible_name = "Submit registration form",
                .size = .large,
                .on_click = cx.on(State.submit, .{}),
            },
            Button{
                .label = "Reset",
                .accessible_name = "Reset form to default values",
                .variant = .secondary,
                .size = .large,
                .on_click = cx.on(State.reset, .{}),
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

    pub fn render(self: FormField, cx: *Cx) void {
        const color = if (self.error_message != null) error_color else label_color;
        cx.render(ui.box(.{ .style = .{ .gap = 4 } }, .{
            ui.text(self.label, .{ .size = 14, .weight = .medium, .color = .{ .rgba = color } }),
            if (self.error_message) |message| ErrorMessage{ .message = message } else null,
        }));
    }
};

/// An assertive live region, so the error is read when it appears.
const ErrorMessage = struct {
    message: []const u8,

    pub fn render(self: ErrorMessage, cx: *Cx) void {
        assert(self.message.len > 0);
        cx.render(ui.box(.{
            .style = .{ .direction = .row, .gap = 4, .alignment = .center_cross },
            .a11y = .{ .role = .alert, .label = self.message, .live = .assertive },
        }, .{
            ui.text("\u{26A0}", .{ .size = 12, .color = .{ .rgba = error_color } }),
            ui.text(self.message, .{ .size = 12, .color = .{ .rgba = error_color } }),
        }));
    }
};

const SuccessMessage = struct {
    pub fn render(_: SuccessMessage, cx: *Cx) void {
        const green = ui.Color.rgb(0.2, 0.7, 0.3);
        cx.render(ui.box(.{
            .style = .{
                .padding = .all(32),
                .gap = 20,
                .background = .{ .rgba = ui.Color.rgb(0.9, 1.0, 0.9) },
                .corner_radius = .all(12),
                .border = .{ .width = 2, .color = .{ .rgba = green } },
                .alignment = .center,
            },
            .a11y = .{
                .role = .alert,
                .label = "Registration successful! Thank you for signing up.",
                .live = .assertive,
            },
        }, .{
            ui.text("\u{2713}", .{ .size = 48, .color = .{ .rgba = green } }),
            ui.text("Registration Successful!", .{
                .size = 24,
                .weight = .bold,
                .color = .{ .rgba = ui.Color.rgb(0.2, 0.5, 0.3) },
            }),
            ui.text("Thank you for signing up. We'll be in touch soon.", .{
                .size = 16,
                .color = .{ .rgba = ui.Color.rgb(0.3, 0.5, 0.4) },
            }),
            Button{
                .label = "Submit Another Response",
                .accessible_name = "Start a new registration",
                .on_click = cx.on(State.dismissSuccess, .{}),
            },
        }));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "form validation" {
    var s = State{};
    try std.testing.expect(!s.validate());
    try std.testing.expect(s.validation_errors.name);
    try std.testing.expect(s.validation_errors.email);
    try std.testing.expect(s.validation_errors.terms);

    s.name = "John Doe";
    s.email = "john@example.com";
    s.terms_accepted = true;
    try std.testing.expect(s.validate());
    try std.testing.expect(!s.validation_errors.name);
    try std.testing.expect(!s.validation_errors.email);
    try std.testing.expect(!s.validation_errors.terms);
}

test "form reset" {
    var s = State{};
    s.name = "Test";
    s.newsletter = false;
    s.terms_accepted = true;
    s.form_submitted = true;
    s.reset();
    try std.testing.expectEqualStrings("", s.name);
    try std.testing.expect(s.newsletter);
    try std.testing.expect(!s.terms_accepted);
    try std.testing.expect(!s.form_submitted);
}
