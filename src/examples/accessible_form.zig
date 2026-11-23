const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Handler = gooey.Handler;
const Button = components.Button;
const Checkbox = components.Checkbox;
const TextInput = components.TextInput;
const Select = components.Select;
const RadioGroup = components.RadioGroup;
const Switch = components.Switch;
const Slider = components.Slider;
const Tooltip = components.Tooltip;

pub const State = struct {
    name: []const u8 = "",
    email: []const u8 = "",
    phone: []const u8 = "",

    contact_method: ContactMethod = .email,
    newsletter: bool = true,
    terms_accepted: bool = false,

    experience_level: ?usize = null,

    notifications: bool = true,
    sms_alerts: bool = false,
    emails_per_week: f32 = 3,

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

    pub fn toggleNotifications(self: *State) void {
        self.notifications = !self.notifications;
    }

    pub fn toggleSmsAlerts(self: *State) void {
        self.sms_alerts = !self.sms_alerts;
    }

    pub fn setContact(self: *State, method: ContactMethod) void {
        self.contact_method = method;
        assert(self.contact_method == method);
    }

    pub fn selectExperience(self: *State, index: u32) void {
        assert(index < experience_options.len);
        self.experience_level = index;
        assert(self.experience_level.? == index);
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

pub const App = gooey.App(State, render, .{
    .title = "Accessible Form Example",
    .width = 600,
    .height = 800,
    .limits = .small,
    .keymap = gooey.keymaps.text_default,
});

pub const main = App.main;

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
            ExperienceSection{ .experience_level = s.experience_level },
            NotificationsSection{},
            TermsSection{
                .terms_accepted = s.terms_accepted,
                .has_error = s.validation_errors.terms,
            },
            FormActions{},
        }));
    }
};

const error_color = ui.Color.rgb(0.9, 0.3, 0.3);
const title_color = ui.Color.rgb(0.2, 0.2, 0.3);
const label_color = ui.Color.rgb(0.3, 0.3, 0.4);

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

    const labels = [_][]const u8{ "Email", "Phone", "Postal Mail" };

    pub fn render(self: ContactPreferencesSection, cx: *Cx) void {
        const methods = comptime std.enums.values(State.ContactMethod);
        comptime assert(methods.len == labels.len);
        var on_select: [methods.len]Handler = undefined;
        for (&on_select, methods) |*handler, method| {
            handler.* = cx.on(State.setContact, .{ .arg = method });
        }
        cx.render(ui.box(card(null, false), .{
            sectionHeading("Contact Preferences"),
            RadioGroup{
                .key = "contact-method",
                .options = &labels,
                .on_select = &on_select,
                .selected = @backingInt(self.contact_method),
                .label = "Preferred Contact Method",
            },
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

const ExperienceSection = struct {
    experience_level: ?usize,

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
                .selected = self.experience_level,
                .placeholder = "Select your experience level",
                .width = 260,
                .accessible_name = "Experience level",
                .accessible_description = "Select how experienced you are with our products",
            },
        }));
    }
};

const NotificationsSection = struct {
    pub fn render(_: NotificationsSection, cx: *Cx) void {
        const s = cx.state(State);
        const sms_available = s.phone.len > 0;
        var count_buffer: [32]u8 = undefined;
        comptime assert(std.fmt.count("{d} per week", .{std.math.maxInt(u32)}) <= count_buffer.len);
        const count = std.fmt.bufPrint(&count_buffer, "{d} per week", .{
            @as(u32, @intFromFloat(s.emails_per_week)),
        }) catch unreachable;
        cx.render(ui.box(card("Notification settings", false), .{
            sectionHeading("Notifications"),
            Switch{
                .key = .{ .name = "notifications" },
                .checked = s.notifications,
                .label = "Email notifications",
                .on_click = cx.on(State.toggleNotifications, .{}),
            },
            Switch{
                .key = .{ .name = "sms-alerts" },
                .checked = s.sms_alerts,
                .label = "SMS alerts",
                .disabled = !sms_available,
                .accessible_description = if (sms_available)
                    null
                else
                    "Add a phone number to turn on SMS alerts",
                .on_click = cx.on(State.toggleSmsAlerts, .{}),
            },
            FormField{ .label = "Emails per week", .error_message = null },
            ui.box(.{ .style = .{
                .direction = .row,
                .gap = 16,
                .alignment = .center_cross,
            } }, .{
                Slider{
                    .key = "emails-per-week",
                    .bind = &s.emails_per_week,
                    .min = 1,
                    .max = 7,
                    .step = 1,
                    .width = 260,
                    .disabled = !s.notifications,
                    .accessible_name = "Emails per week",
                },
                ui.text(count, .{ .size = 14, .color = .{ .rgba = label_color } }),
            }),
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
            Tooltip(Button){
                .key = "reset-tooltip",
                .text = "Clears every field and choice",
                .child = .{
                    .label = "Reset",
                    .accessible_name = "Reset form to default values",
                    .variant = .secondary,
                    .size = .large,
                    .on_click = cx.on(State.reset, .{}),
                },
            },
        }));
    }
};

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
