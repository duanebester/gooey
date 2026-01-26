//! ValidatedTextInput Component
//!
//! A text input with integrated label, error display, and help text.
//! Bundles common form field patterns into a single convenient component.
//!
//! ## Accessibility Features
//!
//! - `aria-invalid`: Automatically set when field has a visible error
//! - `aria-required`: Set when `required_indicator` is true
//! - `aria-describedby`: Links input to error message for screen readers
//! - Live region: Error messages are announced to screen readers
//!
//! ## Usage
//!
//! ```zig
//! gooey.ValidatedTextInput{
//!     .id = "email",
//!     .label = "Email Address",
//!     .required_indicator = true,
//!     .bind = &state.email,
//!     .error_message = if (state.touched.email) validation.email(state.email) else null,
//!     .on_blur_handler = cx.update(State.onEmailBlur),
//! }
//! ```

const std = @import("std");
const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const HandlerRef = ui.HandlerRef;
const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;
const a11y = @import("../accessibility/accessibility.zig");
const validation = @import("../validation.zig");

pub const ValidatedTextInput = struct {
    // =========================================================================
    // Required
    // =========================================================================

    /// Unique identifier for the input (required for state retention)
    id: []const u8,

    // =========================================================================
    // Binding
    // =========================================================================

    /// Bind to a string for two-way data binding
    bind: ?*[]const u8 = null,

    // =========================================================================
    // Validation Display
    // =========================================================================

    /// Error message to display (null = no error).
    /// For simple string-based validation.
    error_message: ?[]const u8 = null,

    /// Structured validation result with error code and separate messages
    /// for visual display vs screen readers. Takes precedence over error_message.
    /// Use for full a11y control or programmatic error handling.
    ///
    /// Example:
    /// ```zig
    /// .error_result = validation.requiredResult(state.email, .{
    ///     .message = "Required",  // Terse for visual
    ///     .accessible_message = "The email field is required",  // Verbose for screen readers
    /// }),
    /// ```
    error_result: ?validation.Result = null,

    /// Only show error if true (use for touched state tracking)
    /// When false, error is hidden even if set
    show_error: bool = true,

    // =========================================================================
    // Labels & Text
    // =========================================================================

    /// Label shown above the input
    label: ?[]const u8 = null,

    /// Placeholder text inside the input
    placeholder: []const u8 = "",

    /// Help text shown below the input (when no error)
    help_text: ?[]const u8 = null,

    /// Show "*" after label to indicate required field
    required_indicator: bool = false,

    // =========================================================================
    // Handlers
    // =========================================================================

    /// Handler called when input loses focus
    on_blur_handler: ?HandlerRef = null,

    // =========================================================================
    // Input Options
    // =========================================================================

    /// Mask input for passwords
    secure: bool = false,

    // =========================================================================
    // Layout
    // =========================================================================

    /// Width of the entire field (including label)
    width: ?f32 = null,

    /// Height of the input portion (null = auto)
    input_height: ?f32 = null,

    /// Padding inside the input
    input_padding: f32 = 8,

    /// Gap between label, input, and helper text
    gap: f32 = 6,

    // =========================================================================
    // Styling (null = use theme)
    // =========================================================================

    /// Input background color
    background: ?Color = null,

    /// Input border color (unfocused)
    border_color: ?Color = null,

    /// Input border color (focused)
    border_color_focused: ?Color = null,

    /// Input border color (error state)
    border_color_error: ?Color = null,

    /// Border width
    border_width: f32 = 1,

    /// Corner radius
    corner_radius: ?f32 = null,

    /// Input text color
    text_color: ?Color = null,

    /// Placeholder text color
    placeholder_color: ?Color = null,

    /// Text selection color
    selection_color: ?Color = null,

    /// Cursor color
    cursor_color: ?Color = null,

    /// Label text color
    label_color: ?Color = null,

    /// Error text color
    error_color: ?Color = null,

    /// Help text color
    help_text_color: ?Color = null,

    /// Label font size
    label_size: u16 = 14,

    /// Error/help text font size
    helper_size: u16 = 12,

    // =========================================================================
    // Focus Navigation
    // =========================================================================

    tab_index: i32 = 0,
    tab_stop: bool = true,

    // =========================================================================
    // Accessibility
    // =========================================================================

    /// Override label for screen readers
    accessible_name: ?[]const u8 = null,

    /// Additional description for screen readers
    accessible_description: ?[]const u8 = null,

    /// Announce errors via live region (default: polite)
    /// Set to .assertive for critical validation errors
    error_live_region: a11y.Live = .polite,

    // =========================================================================
    // Render
    // =========================================================================

    pub fn render(self: ValidatedTextInput, b: *ui.Builder) void {
        const t = b.theme();

        // Resolve colors: explicit value OR theme default
        const label_color = self.label_color orelse t.text;
        const error_color = self.error_color orelse t.danger;
        const help_color = self.help_text_color orelse t.muted;

        // Resolve error messages: error_result takes precedence over error_message
        // For visual display, use displayMessage(); for screen readers, use screenReaderMessage()
        const display_error: ?[]const u8 = if (self.error_result) |r|
            r.displayMessage()
        else
            self.error_message;

        const a11y_error: ?[]const u8 = if (self.error_result) |r|
            r.screenReaderMessage()
        else
            self.error_message;

        // Determine if we should show the error
        const has_visible_error = self.show_error and display_error != null;

        // Generate unique ID for error message element (for aria-describedby)
        const error_id = generateErrorId(self.id);

        // Resolve input border color based on error state
        const input_border = if (has_visible_error)
            (self.border_color_error orelse error_color)
        else
            (self.border_color orelse t.border);
        const input_border_focused = if (has_visible_error)
            (self.border_color_error orelse error_color)
        else
            (self.border_color_focused orelse t.border_focus);

        // Container for the whole field
        b.box(.{
            .width = self.width,
            .direction = .column,
            .gap = self.gap,
        }, .{
            // Label row (label + required indicator)
            LabelRow{
                .label = self.label,
                .required_indicator = self.required_indicator,
                .label_color = label_color,
                .error_color = error_color,
                .label_size = self.label_size,
            },

            // The actual input - inline to ensure proper layout sizing
            ui.input(self.id, .{
                .placeholder = self.placeholder,
                .secure = self.secure,
                .bind = self.bind,
                .width = self.width,
                .height = self.input_height,
                .padding = self.input_padding,
                .background = self.background orelse t.surface,
                .border_color = input_border,
                .border_color_focused = input_border_focused,
                .border_width = self.border_width,
                .corner_radius = self.corner_radius orelse t.radius_md,
                .text_color = self.text_color orelse t.text,
                .placeholder_color = self.placeholder_color orelse t.muted,
                .selection_color = self.selection_color orelse t.primary.withAlpha(0.3),
                .cursor_color = self.cursor_color orelse t.text,
                .tab_index = self.tab_index,
                .tab_stop = self.tab_stop,
                .on_blur_handler = self.on_blur_handler,
            }),

            // Error or help text
            HelperText{
                .id = &error_id,
                .error_msg = if (has_visible_error) display_error else null,
                .a11y_error_msg = if (has_visible_error) a11y_error else null,
                .help_text = self.help_text,
                .error_color = error_color,
                .help_color = help_color,
                .helper_size = self.helper_size,
                .live_region = self.error_live_region,
            },
        });
    }

    /// Generate a unique error ID based on the input ID.
    /// Buffer size: 64 bytes = up to 58 chars for input ID + 6 chars for "-error" suffix.
    /// This is sufficient for typical field IDs while keeping stack usage bounded.
    fn generateErrorId(input_id: []const u8) [64]u8 {
        const suffix = "-error";
        comptime std.debug.assert(suffix.len == 6); // Suffix length assumption for max_id_len
        const max_id_len = 64 - suffix.len;
        std.debug.assert(input_id.len > 0); // ID must not be empty
        std.debug.assert(input_id.len <= max_id_len); // ID too long - would be truncated

        var buf: [64]u8 = undefined;
        const copy_len = @min(input_id.len, buf.len - suffix.len);
        @memcpy(buf[0..copy_len], input_id[0..copy_len]);
        @memcpy(buf[copy_len .. copy_len + suffix.len], suffix);
        // Zero-fill the rest
        @memset(buf[copy_len + suffix.len ..], 0);
        return buf;
    }
};

// =============================================================================
// Private Sub-Components
// =============================================================================

const LabelRow = struct {
    label: ?[]const u8,
    required_indicator: bool,
    label_color: Color,
    error_color: Color,
    label_size: u16,

    pub fn render(self: LabelRow, b: *ui.Builder) void {
        if (self.label) |lbl| {
            b.box(.{
                .direction = .row,
                .gap = 2,
            }, .{
                ui.text(lbl, .{
                    .color = self.label_color,
                    .size = self.label_size,
                    .weight = .medium,
                }),
                RequiredIndicator{
                    .show = self.required_indicator,
                    .color = self.error_color,
                    .size = self.label_size,
                },
            });
        }
    }
};

const RequiredIndicator = struct {
    show: bool,
    color: Color,
    size: u16,

    pub fn render(self: RequiredIndicator, b: *ui.Builder) void {
        if (self.show) {
            b.box(.{}, .{
                ui.text("*", .{
                    .color = self.color,
                    .size = self.size,
                    .weight = .bold,
                }),
            });
        }
    }
};

const InputField = struct {
    id: []const u8,
    placeholder: []const u8,
    secure: bool,
    bind: ?*[]const u8,
    width: ?f32,
    height: ?f32,
    padding: f32,
    background: Color,
    border_color: Color,
    border_color_focused: Color,
    border_width: f32,
    corner_radius: f32,
    text_color: Color,
    placeholder_color: Color,
    selection_color: Color,
    cursor_color: Color,
    tab_index: i32,
    tab_stop: bool,
    on_blur_handler: ?HandlerRef,
    accessible_name: ?[]const u8,
    accessible_description: ?[]const u8,
    // Accessibility state
    is_invalid: bool,
    is_required: bool,
    described_by_id: ?*const [64]u8,

    pub fn render(self: InputField, b: *ui.Builder) void {
        const layout_id = LayoutId.fromString(self.id);

        // Build accessibility state
        var a11y_state = a11y.State{};
        if (self.is_invalid) {
            a11y_state.invalid = true;
        }
        if (self.is_required) {
            a11y_state.required = true;
        }

        // Get the described_by_id as a slice (trimming null bytes)
        const described_by: ?[]const u8 = if (self.described_by_id) |id_buf| blk: {
            // Find the actual length (up to first null byte)
            var len: usize = 0;
            while (len < id_buf.len and id_buf[len] != 0) : (len += 1) {}
            break :blk if (len > 0) id_buf[0..len] else null;
        } else null;

        // Push accessible element (role: textbox)
        const a11y_value: ?[]const u8 = if (self.secure)
            null
        else if (self.bind) |binding|
            if (binding.len > 0) binding.* else null
        else
            null;

        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .textbox,
            .name = self.accessible_name orelse self.placeholder,
            .description = self.accessible_description,
            .value = a11y_value,
            .state = a11y_state,
            .described_by_id = described_by,
        });
        defer if (a11y_pushed) b.accessibleEnd();

        // Use fill_width so box expands horizontally within parent column,
        // height will fit to the input child automatically.
        b.box(.{
            .fill_width = true,
        }, .{
            ui.input(self.id, .{
                .placeholder = self.placeholder,
                .secure = self.secure,
                .bind = self.bind,
                .width = self.width,
                .height = self.height,
                .padding = self.padding,
                .background = self.background,
                .border_color = self.border_color,
                .border_color_focused = self.border_color_focused,
                .border_width = self.border_width,
                .corner_radius = self.corner_radius,
                .text_color = self.text_color,
                .placeholder_color = self.placeholder_color,
                .selection_color = self.selection_color,
                .cursor_color = self.cursor_color,
                .tab_index = self.tab_index,
                .tab_stop = self.tab_stop,
                .on_blur_handler = self.on_blur_handler,
            }),
        });
    }
};

const HelperText = struct {
    id: *const [64]u8,
    error_msg: ?[]const u8,
    /// Separate message for screen readers (falls back to error_msg if null)
    a11y_error_msg: ?[]const u8 = null,
    help_text: ?[]const u8,
    error_color: Color,
    help_color: Color,
    helper_size: u16,
    live_region: a11y.Live,

    pub fn render(self: HelperText, b: *ui.Builder) void {
        // Get the ID as a slice (trimming null bytes)
        var id_len: usize = 0;
        while (id_len < self.id.len and self.id[id_len] != 0) : (id_len += 1) {}
        const id_slice = self.id[0..id_len];
        const layout_id = LayoutId.fromString(id_slice);

        const min_height = @as(f32, @floatFromInt(self.helper_size)) + 4;

        // Error takes precedence over help text
        // Always render a box with min_height to prevent layout shift and ensure
        // proper column stacking (empty box reserves space when no message)
        if (self.error_msg) |err| {
            // Use a11y_error_msg for screen readers if provided, otherwise fall back to err
            const screen_reader_msg = self.a11y_error_msg orelse err;

            // Push accessible element for error with live region
            // This enables screen readers to announce validation errors
            const a11y_pushed = b.accessible(.{
                .layout_id = layout_id,
                .role = .alert,
                .name = screen_reader_msg,
                .live = self.live_region,
            });
            defer if (a11y_pushed) b.accessibleEnd();

            // Display the visual error message (may differ from screen reader message)
            b.box(.{ .min_height = min_height }, .{
                ui.text(err, .{
                    .color = self.error_color,
                    .size = self.helper_size,
                }),
            });
        } else if (self.help_text) |help| {
            b.box(.{ .min_height = min_height }, .{
                ui.text(help, .{
                    .color = self.help_color,
                    .size = self.helper_size,
                }),
            });
        } else {
            // Empty placeholder to maintain consistent layout
            b.box(.{ .min_height = min_height }, .{});
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "generateErrorId creates correct ID" {
    const input_id = "email";
    const error_id = ValidatedTextInput.generateErrorId(input_id);

    // Find actual length
    var len: usize = 0;
    while (len < error_id.len and error_id[len] != 0) : (len += 1) {}

    try std.testing.expectEqualStrings("email-error", error_id[0..len]);
}

test "generateErrorId handles max-length IDs" {
    // Create a 58-char ID (max allowed: 64 - 6 for "-error" suffix)
    const max_id = "this-is-exactly-fifty-eight-characters-for-the-input-id-xx";
    try std.testing.expectEqual(@as(usize, 58), max_id.len);

    const error_id = ValidatedTextInput.generateErrorId(max_id);

    // Should produce full 64-char result
    var len: usize = 0;
    while (len < error_id.len and error_id[len] != 0) : (len += 1) {}

    // Should be exactly 64 chars (58 + 6 for "-error")
    try std.testing.expectEqual(@as(usize, 64), len);
    try std.testing.expect(std.mem.endsWith(u8, error_id[0..len], "-error"));
}
