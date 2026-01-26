//! Form Validation Utilities
//!
//! Pure, testable validation functions for form fields with i18n support.
//!
//! ## API Levels
//!
//! ### Level 1: Simple (English messages)
//! ```zig
//! const err = validation.required(value);  // Returns ?[]const u8
//! ```
//!
//! ### Level 2: Custom Messages (i18n)
//! ```zig
//! const french = struct {
//!     pub const required = validation.requiredMsg("Ce champ est requis");
//!     pub const email = validation.emailMsg("Adresse e-mail invalide");
//! };
//! const err = french.required(value);
//! const err = validation.all(value, .{ french.required, french.email });
//! ```
//!
//! ### Level 3: Error Codes (programmatic handling)
//! ```zig
//! const code = validation.requiredCode(value);  // Returns ?ErrorCode
//! if (code == .required) {
//!     cx.setFocus("username");  // Focus first invalid field
//! }
//! ```
//!
//! ### Level 4: Structured Results (full a11y control)
//! ```zig
//! const result = validation.requiredResult(value, .{
//!     .message = "Required",  // Terse for visual
//!     .accessible_message = "The username field is required",  // Verbose for screen readers
//! });
//! if (result) |r| {
//!     // r.code, r.displayMessage(), r.screenReaderMessage()
//! }
//! ```

const std = @import("std");

// =============================================================================
// Core Types
// =============================================================================

/// Result of validating a single field.
/// null = valid, non-null = error message
pub const FieldResult = ?[]const u8;

/// A validation error with field identifier
pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,
};

/// Type for validator functions
pub const ValidatorFn = *const fn ([]const u8) FieldResult;

/// Error codes for programmatic handling of validation errors.
/// Use these when you need to:
/// - Focus the first invalid field
/// - Log/track validation failures
/// - Apply custom styling per error type
pub const ErrorCode = enum {
    required,
    min_length,
    max_length,
    invalid_email,
    invalid_format,
    not_numeric,
    not_alphanumeric,
    mismatch,
    no_uppercase,
    no_lowercase,
    no_digit,
    no_special_char,
};

/// Structured validation result with error code and messages.
/// Supports different messages for visual display vs screen readers.
pub const Result = struct {
    /// Error code for programmatic handling
    code: ErrorCode,
    /// Message for visual display
    message: []const u8,
    /// Optional override for screen readers (null = use message)
    accessible_message: ?[]const u8 = null,

    /// Get the message for visual display
    pub fn displayMessage(self: Result) []const u8 {
        return self.message;
    }

    /// Get the message for screen readers (falls back to display message)
    pub fn screenReaderMessage(self: Result) []const u8 {
        return self.accessible_message orelse self.message;
    }
};

/// Options for creating a structured Result
pub const ResultOptions = struct {
    /// Message for visual display
    message: []const u8,
    /// Optional override for screen readers
    accessible_message: ?[]const u8 = null,
};

// =============================================================================
// Default Messages (English)
// =============================================================================

const DefaultMessages = struct {
    const required_msg = "This field is required";
    const min_length_msg = "Value is too short";
    const max_length_msg = "Value is too long";
    const email_msg = "Invalid email address";
    const numeric_msg = "Must contain only numbers";
    const alphanumeric_msg = "Must contain only letters and numbers";
    const matches_msg = "Values do not match";
    const uppercase_msg = "Must contain at least one uppercase letter";
    const lowercase_msg = "Must contain at least one lowercase letter";
    const digit_msg = "Must contain at least one number";
    const special_char_msg = "Must contain at least one special character";
};

// =============================================================================
// Level 1: Simple Validators (Pure Functions, English Messages)
// =============================================================================

/// Validates that the value is not empty or whitespace-only.
pub fn required(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);

    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    if (trimmed.len == 0) {
        return DefaultMessages.required_msg;
    }
    return null;
}

/// Validates that the value has at least `min` characters.
pub fn minLength(value: []const u8, min: usize) FieldResult {
    std.debug.assert(min <= 10000);
    std.debug.assert(value.len <= 1024 * 1024);

    if (value.len < min) {
        return DefaultMessages.min_length_msg;
    }
    return null;
}

/// Validates that the value has at most `max` characters.
pub fn maxLength(value: []const u8, max: usize) FieldResult {
    std.debug.assert(max > 0);
    std.debug.assert(max <= 1024 * 1024);

    if (value.len > max) {
        return DefaultMessages.max_length_msg;
    }
    return null;
}

/// Validates that the value is a valid email address (basic check).
pub fn email(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 320);

    if (value.len == 0) return null;

    const at_index = std.mem.indexOf(u8, value, "@") orelse {
        return DefaultMessages.email_msg;
    };

    if (at_index == 0) {
        return DefaultMessages.email_msg;
    }

    const domain = value[at_index + 1 ..];
    if (domain.len == 0) {
        return DefaultMessages.email_msg;
    }

    const dot_index = std.mem.indexOf(u8, domain, ".") orelse {
        return DefaultMessages.email_msg;
    };

    if (dot_index == 0 or dot_index == domain.len - 1) {
        return DefaultMessages.email_msg;
    }

    if (std.mem.indexOf(u8, domain, "..") != null) {
        return DefaultMessages.email_msg;
    }

    return null;
}

/// Validates that the value contains only numeric digits (0-9).
pub fn numeric(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);

    if (value.len == 0) return null;

    for (value) |c| {
        if (c < '0' or c > '9') {
            return DefaultMessages.numeric_msg;
        }
    }
    return null;
}

/// Validates that the value contains only alphanumeric characters.
pub fn alphanumeric(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);

    if (value.len == 0) return null;

    for (value) |c| {
        const is_digit = c >= '0' and c <= '9';
        const is_lower = c >= 'a' and c <= 'z';
        const is_upper = c >= 'A' and c <= 'Z';
        if (!is_digit and !is_lower and !is_upper) {
            return DefaultMessages.alphanumeric_msg;
        }
    }
    return null;
}

/// Validates that the value matches another value (e.g., confirm password).
pub fn matches(value: []const u8, other: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);
    std.debug.assert(other.len <= 1024 * 1024);

    if (!std.mem.eql(u8, value, other)) {
        return DefaultMessages.matches_msg;
    }
    return null;
}

/// Validates that the value contains at least one uppercase letter.
pub fn hasUppercase(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);

    for (value) |c| {
        if (c >= 'A' and c <= 'Z') return null;
    }
    return DefaultMessages.uppercase_msg;
}

/// Validates that the value contains at least one lowercase letter.
pub fn hasLowercase(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);

    for (value) |c| {
        if (c >= 'a' and c <= 'z') return null;
    }
    return DefaultMessages.lowercase_msg;
}

/// Validates that the value contains at least one digit.
pub fn hasDigit(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);

    for (value) |c| {
        if (c >= '0' and c <= '9') return null;
    }
    return DefaultMessages.digit_msg;
}

/// Validates that the value contains at least one special character.
pub fn hasSpecialChar(value: []const u8) FieldResult {
    std.debug.assert(value.len <= 1024 * 1024);

    const special = "!@#$%^&*()_+-=[]{}|;':\",./<>?`~";
    for (value) |c| {
        if (std.mem.indexOf(u8, special, &[_]u8{c}) != null) return null;
    }
    return DefaultMessages.special_char_msg;
}

// =============================================================================
// Level 2: Message Factories (Custom Messages for i18n)
// =============================================================================

/// Creates a required validator with a custom message.
/// Use for i18n: `const required_fr = validation.requiredMsg("Ce champ est requis");`
pub fn requiredMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            const trimmed = std.mem.trim(u8, value, " \t\n\r");
            if (trimmed.len == 0) {
                return message;
            }
            return null;
        }
    }.validate;
}

/// Creates an email validator with a custom message.
pub fn emailMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 320);
            if (value.len == 0) return null;

            const at_index = std.mem.indexOf(u8, value, "@") orelse return message;
            if (at_index == 0) return message;

            const domain = value[at_index + 1 ..];
            if (domain.len == 0) return message;

            const dot_index = std.mem.indexOf(u8, domain, ".") orelse return message;
            if (dot_index == 0 or dot_index == domain.len - 1) return message;
            if (std.mem.indexOf(u8, domain, "..") != null) return message;

            return null;
        }
    }.validate;
}

/// Creates a min length validator with a custom message.
pub fn minLengthMsg(comptime min: usize, comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            if (value.len < min) {
                return message;
            }
            return null;
        }
    }.validate;
}

/// Creates a max length validator with a custom message.
pub fn maxLengthMsg(comptime max: usize, comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            if (value.len > max) {
                return message;
            }
            return null;
        }
    }.validate;
}

/// Creates a numeric validator with a custom message.
pub fn numericMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            if (value.len == 0) return null;
            for (value) |c| {
                if (c < '0' or c > '9') return message;
            }
            return null;
        }
    }.validate;
}

/// Creates an alphanumeric validator with a custom message.
pub fn alphanumericMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            if (value.len == 0) return null;
            for (value) |c| {
                const is_valid = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
                if (!is_valid) return message;
            }
            return null;
        }
    }.validate;
}

/// Creates a hasUppercase validator with a custom message.
pub fn hasUppercaseMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            for (value) |c| {
                if (c >= 'A' and c <= 'Z') return null;
            }
            return message;
        }
    }.validate;
}

/// Creates a hasLowercase validator with a custom message.
pub fn hasLowercaseMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            for (value) |c| {
                if (c >= 'a' and c <= 'z') return null;
            }
            return message;
        }
    }.validate;
}

/// Creates a hasDigit validator with a custom message.
pub fn hasDigitMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            for (value) |c| {
                if (c >= '0' and c <= '9') return null;
            }
            return message;
        }
    }.validate;
}

/// Creates a hasSpecialChar validator with a custom message.
pub fn hasSpecialCharMsg(comptime message: []const u8) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            const special = "!@#$%^&*()_+-=[]{}|;':\",./<>?`~";
            for (value) |c| {
                if (std.mem.indexOf(u8, special, &[_]u8{c}) != null) return null;
            }
            return message;
        }
    }.validate;
}

/// Creates a matches validator with a custom message.
/// Note: Returns a function that takes (value, other) - not compatible with `all()`.
pub fn matchesMsg(comptime message: []const u8) *const fn ([]const u8, []const u8) FieldResult {
    return struct {
        fn validate(value: []const u8, other: []const u8) FieldResult {
            std.debug.assert(value.len <= 1024 * 1024);
            std.debug.assert(other.len <= 1024 * 1024);
            if (!std.mem.eql(u8, value, other)) {
                return message;
            }
            return null;
        }
    }.validate;
}

// =============================================================================
// Level 3: Error Code Functions (Programmatic Handling)
// =============================================================================

/// Validates required and returns error code.
pub fn requiredCode(value: []const u8) ?ErrorCode {
    if (required(value) != null) return .required;
    return null;
}

/// Validates email and returns error code.
pub fn emailCode(value: []const u8) ?ErrorCode {
    if (email(value) != null) return .invalid_email;
    return null;
}

/// Validates min length and returns error code.
pub fn minLengthCode(value: []const u8, min: usize) ?ErrorCode {
    if (minLength(value, min) != null) return .min_length;
    return null;
}

/// Validates max length and returns error code.
pub fn maxLengthCode(value: []const u8, max: usize) ?ErrorCode {
    if (maxLength(value, max) != null) return .max_length;
    return null;
}

/// Validates numeric and returns error code.
pub fn numericCode(value: []const u8) ?ErrorCode {
    if (numeric(value) != null) return .not_numeric;
    return null;
}

/// Validates alphanumeric and returns error code.
pub fn alphanumericCode(value: []const u8) ?ErrorCode {
    if (alphanumeric(value) != null) return .not_alphanumeric;
    return null;
}

/// Validates matches and returns error code.
pub fn matchesCode(value: []const u8, other: []const u8) ?ErrorCode {
    if (matches(value, other) != null) return .mismatch;
    return null;
}

/// Validates hasUppercase and returns error code.
pub fn hasUppercaseCode(value: []const u8) ?ErrorCode {
    if (hasUppercase(value) != null) return .no_uppercase;
    return null;
}

/// Validates hasLowercase and returns error code.
pub fn hasLowercaseCode(value: []const u8) ?ErrorCode {
    if (hasLowercase(value) != null) return .no_lowercase;
    return null;
}

/// Validates hasDigit and returns error code.
pub fn hasDigitCode(value: []const u8) ?ErrorCode {
    if (hasDigit(value) != null) return .no_digit;
    return null;
}

/// Validates hasSpecialChar and returns error code.
pub fn hasSpecialCharCode(value: []const u8) ?ErrorCode {
    if (hasSpecialChar(value) != null) return .no_special_char;
    return null;
}

// =============================================================================
// Level 4: Structured Result Functions (Full A11y Control)
// =============================================================================

/// Validates required and returns structured Result with custom messages.
pub fn requiredResult(value: []const u8, opts: ResultOptions) ?Result {
    std.debug.assert(value.len <= 1024 * 1024);
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    if (trimmed.len == 0) {
        return .{
            .code = .required,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates email and returns structured Result with custom messages.
pub fn emailResult(value: []const u8, opts: ResultOptions) ?Result {
    std.debug.assert(value.len <= 320);
    if (email(value) != null) {
        return .{
            .code = .invalid_email,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates min length and returns structured Result with custom messages.
pub fn minLengthResult(value: []const u8, min: usize, opts: ResultOptions) ?Result {
    if (minLength(value, min) != null) {
        return .{
            .code = .min_length,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates max length and returns structured Result with custom messages.
pub fn maxLengthResult(value: []const u8, max: usize, opts: ResultOptions) ?Result {
    if (maxLength(value, max) != null) {
        return .{
            .code = .max_length,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates matches and returns structured Result with custom messages.
pub fn matchesResult(value: []const u8, other: []const u8, opts: ResultOptions) ?Result {
    if (matches(value, other) != null) {
        return .{
            .code = .mismatch,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates hasUppercase and returns structured Result with custom messages.
pub fn hasUppercaseResult(value: []const u8, opts: ResultOptions) ?Result {
    if (hasUppercase(value) != null) {
        return .{
            .code = .no_uppercase,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates hasLowercase and returns structured Result with custom messages.
pub fn hasLowercaseResult(value: []const u8, opts: ResultOptions) ?Result {
    if (hasLowercase(value) != null) {
        return .{
            .code = .no_lowercase,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates hasDigit and returns structured Result with custom messages.
pub fn hasDigitResult(value: []const u8, opts: ResultOptions) ?Result {
    if (hasDigit(value) != null) {
        return .{
            .code = .no_digit,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

/// Validates hasSpecialChar and returns structured Result with custom messages.
pub fn hasSpecialCharResult(value: []const u8, opts: ResultOptions) ?Result {
    if (hasSpecialChar(value) != null) {
        return .{
            .code = .no_special_char,
            .message = opts.message,
            .accessible_message = opts.accessible_message,
        };
    }
    return null;
}

// =============================================================================
// Validator Factories (for use with `all` combinator)
// =============================================================================

/// Creates a min length validator function (with default message).
pub fn minLengthValidator(comptime min: usize) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            return minLength(value, min);
        }
    }.validate;
}

/// Creates a max length validator function (with default message).
pub fn maxLengthValidator(comptime max: usize) ValidatorFn {
    return struct {
        fn validate(value: []const u8) FieldResult {
            return maxLength(value, max);
        }
    }.validate;
}

// =============================================================================
// Combinator
// =============================================================================

/// Runs multiple validators on a value, returning the first error or null if all pass.
///
/// Example:
/// ```zig
/// const err = validation.all(value, .{
///     validation.required,
///     validation.minLengthValidator(8),
///     validation.email,
/// });
/// ```
pub fn all(value: []const u8, validators: anytype) FieldResult {
    const T = @TypeOf(validators);
    const fields = @typeInfo(T).@"struct".fields;

    std.debug.assert(fields.len > 0);
    std.debug.assert(fields.len <= 16);

    inline for (fields) |field| {
        const validator = @field(validators, field.name);
        if (validator(value)) |err| {
            return err;
        }
    }
    return null;
}

// =============================================================================
// Form-Level Helpers
// =============================================================================

/// A fixed-capacity error storage for form fields.
/// Each index corresponds to a field in your form.
///
/// The 64-field limit is chosen to:
/// - Keep stack allocation bounded (64 optional slices = 1KB on 64-bit)
/// - Cover virtually all real-world forms (most have <20 fields)
/// - Align with cache line multiples for efficient iteration
///
/// Example:
/// ```zig
/// const FormField = enum(usize) { email = 0, password = 1, confirm = 2 };
/// var errors = validation.FormErrors(3).init();
///
/// errors.set(@intFromEnum(FormField.email), validation.email(state.email));
/// errors.set(@intFromEnum(FormField.password), validation.required(state.password));
///
/// if (!errors.isValid()) {
///     // Show errors
/// }
/// ```
pub fn FormErrors(comptime max_fields: usize) type {
    std.debug.assert(max_fields > 0);
    std.debug.assert(max_fields <= 64);

    return struct {
        const Self = @This();

        errors: [max_fields]?[]const u8,

        /// Initialize with no errors.
        pub fn init() Self {
            return .{
                .errors = [_]?[]const u8{null} ** max_fields,
            };
        }

        /// Returns true if all fields are valid (no errors).
        pub fn isValid(self: *const Self) bool {
            for (self.errors) |err| {
                if (err != null) return false;
            }
            return true;
        }

        /// Get error for a specific field index.
        pub fn get(self: *const Self, index: usize) ?[]const u8 {
            std.debug.assert(index < max_fields);
            return self.errors[index];
        }

        /// Set error for a specific field index.
        pub fn set(self: *Self, index: usize, err: ?[]const u8) void {
            std.debug.assert(index < max_fields);
            self.errors[index] = err;
        }

        /// Clear all errors.
        pub fn clear(self: *Self) void {
            self.errors = [_]?[]const u8{null} ** max_fields;
        }

        /// Returns the number of fields with errors.
        pub fn errorCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.errors) |err| {
                if (err != null) count += 1;
            }
            return count;
        }

        /// Returns the index of the first field with an error, or null if all valid.
        pub fn firstErrorIndex(self: *const Self) ?usize {
            for (self.errors, 0..) |err, i| {
                if (err != null) return i;
            }
            return null;
        }
    };
}

/// Tracks which fields have been touched (interacted with).
/// Only show validation errors for touched fields.
pub fn TouchedFields(comptime max_fields: usize) type {
    std.debug.assert(max_fields > 0);
    std.debug.assert(max_fields <= 64);

    return struct {
        const Self = @This();

        touched: [max_fields]bool,

        /// Initialize with no fields touched.
        pub fn init() Self {
            return .{
                .touched = [_]bool{false} ** max_fields,
            };
        }

        /// Mark a field as touched.
        pub fn touch(self: *Self, index: usize) void {
            std.debug.assert(index < max_fields);
            self.touched[index] = true;
        }

        /// Check if a field has been touched.
        pub fn isTouched(self: *const Self, index: usize) bool {
            std.debug.assert(index < max_fields);
            return self.touched[index];
        }

        /// Mark all fields as touched (useful on form submit).
        pub fn touchAll(self: *Self) void {
            self.touched = [_]bool{true} ** max_fields;
        }

        /// Reset all fields to untouched.
        pub fn reset(self: *Self) void {
            self.touched = [_]bool{false} ** max_fields;
        }

        /// Get error only if field is touched.
        pub fn getErrorIfTouched(self: *const Self, index: usize, errors: anytype) ?[]const u8 {
            if (!self.isTouched(index)) return null;
            return errors.get(index);
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "required validator" {
    const testing = std.testing;

    try testing.expect(required("") != null);
    try testing.expect(required("   ") != null);
    try testing.expect(required("\t\n") != null);
    try testing.expect(required("hello") == null);
    try testing.expect(required(" hello ") == null);
}

test "minLength validator" {
    const testing = std.testing;

    try testing.expect(minLength("", 1) != null);
    try testing.expect(minLength("ab", 3) != null);
    try testing.expect(minLength("abc", 3) == null);
    try testing.expect(minLength("abcd", 3) == null);
}

test "maxLength validator" {
    const testing = std.testing;

    try testing.expect(maxLength("", 3) == null);
    try testing.expect(maxLength("ab", 3) == null);
    try testing.expect(maxLength("abc", 3) == null);
    try testing.expect(maxLength("abcd", 3) != null);
}

test "email validator" {
    const testing = std.testing;

    try testing.expect(email("") == null);
    try testing.expect(email("test@example.com") == null);
    try testing.expect(email("user.name@domain.co.uk") == null);
    try testing.expect(email("a@b.c") == null);

    try testing.expect(email("invalid") != null);
    try testing.expect(email("@example.com") != null);
    try testing.expect(email("test@") != null);
    try testing.expect(email("test@example") != null);
    try testing.expect(email("test@.com") != null);
    try testing.expect(email("test@example.") != null);
    try testing.expect(email("test@example..com") != null);
}

test "numeric validator" {
    const testing = std.testing;

    try testing.expect(numeric("") == null);
    try testing.expect(numeric("123") == null);
    try testing.expect(numeric("0") == null);
    try testing.expect(numeric("abc") != null);
    try testing.expect(numeric("12a3") != null);
    try testing.expect(numeric("12.3") != null);
}

test "alphanumeric validator" {
    const testing = std.testing;

    try testing.expect(alphanumeric("") == null);
    try testing.expect(alphanumeric("abc") == null);
    try testing.expect(alphanumeric("ABC") == null);
    try testing.expect(alphanumeric("123") == null);
    try testing.expect(alphanumeric("abc123") == null);
    try testing.expect(alphanumeric("abc_123") != null);
    try testing.expect(alphanumeric("abc 123") != null);
}

test "matches validator" {
    const testing = std.testing;

    try testing.expect(matches("password", "password") == null);
    try testing.expect(matches("password", "different") != null);
    try testing.expect(matches("", "") == null);
}

test "password strength validators" {
    const testing = std.testing;

    try testing.expect(hasUppercase("ABC") == null);
    try testing.expect(hasUppercase("abc") != null);
    try testing.expect(hasLowercase("abc") == null);
    try testing.expect(hasLowercase("ABC") != null);
    try testing.expect(hasDigit("123") == null);
    try testing.expect(hasDigit("abc") != null);
    try testing.expect(hasSpecialChar("!@#") == null);
    try testing.expect(hasSpecialChar("abc") != null);
}

test "all combinator" {
    const testing = std.testing;

    // All pass
    const result1 = all("test@example.com", .{
        required,
        email,
    });
    try testing.expect(result1 == null);

    // First fails
    const result2 = all("", .{
        required,
        email,
    });
    try testing.expect(result2 != null);

    // Second fails
    const result3 = all("notanemail", .{
        required,
        email,
    });
    try testing.expect(result3 != null);
}

test "FormErrors" {
    const testing = std.testing;

    var errors = FormErrors(3).init();

    try testing.expect(errors.isValid());
    try testing.expectEqual(@as(usize, 0), errors.errorCount());

    errors.set(0, "Error 1");
    try testing.expect(!errors.isValid());
    try testing.expectEqual(@as(usize, 1), errors.errorCount());
    try testing.expectEqualStrings("Error 1", errors.get(0).?);

    errors.set(2, "Error 3");
    try testing.expectEqual(@as(usize, 2), errors.errorCount());
    try testing.expectEqual(@as(usize, 0), errors.firstErrorIndex().?);

    errors.clear();
    try testing.expect(errors.isValid());
}

test "TouchedFields" {
    const testing = std.testing;

    var touched = TouchedFields(3).init();

    try testing.expect(!touched.isTouched(0));
    try testing.expect(!touched.isTouched(1));

    touched.touch(0);
    try testing.expect(touched.isTouched(0));
    try testing.expect(!touched.isTouched(1));

    touched.touchAll();
    try testing.expect(touched.isTouched(0));
    try testing.expect(touched.isTouched(1));
    try testing.expect(touched.isTouched(2));

    touched.reset();
    try testing.expect(!touched.isTouched(0));
}

test "TouchedFields with FormErrors" {
    const testing = std.testing;

    var errors = FormErrors(2).init();
    var touched = TouchedFields(2).init();

    errors.set(0, "Required");
    errors.set(1, "Invalid");

    // Untouched fields shouldn't show errors
    try testing.expect(touched.getErrorIfTouched(0, errors) == null);
    try testing.expect(touched.getErrorIfTouched(1, errors) == null);

    // Touch field 0
    touched.touch(0);
    try testing.expectEqualStrings("Required", touched.getErrorIfTouched(0, errors).?);
    try testing.expect(touched.getErrorIfTouched(1, errors) == null);
}

// =============================================================================
// i18n Tests (Level 2: Custom Messages)
// =============================================================================

test "requiredMsg custom message" {
    const testing = std.testing;

    const french_required = requiredMsg("Ce champ est requis");
    try testing.expectEqualStrings("Ce champ est requis", french_required("").?);
    try testing.expect(french_required("hello") == null);
}

test "emailMsg custom message" {
    const testing = std.testing;

    const french_email = emailMsg("Adresse e-mail invalide");
    try testing.expectEqualStrings("Adresse e-mail invalide", french_email("invalid").?);
    try testing.expect(french_email("test@example.com") == null);
}

test "minLengthMsg custom message" {
    const testing = std.testing;

    const french_min = minLengthMsg(8, "Au moins 8 caractères");
    try testing.expectEqualStrings("Au moins 8 caractères", french_min("short").?);
    try testing.expect(french_min("longenough") == null);
}

test "custom messages work with all combinator" {
    const testing = std.testing;

    // Define a "locale" struct with custom validators
    const french = struct {
        pub const req = requiredMsg("Ce champ est requis");
        pub const mail = emailMsg("Adresse e-mail invalide");
    };

    // All pass
    const result1 = all("test@example.com", .{ french.req, french.mail });
    try testing.expect(result1 == null);

    // First fails - should get French message
    const result2 = all("", .{ french.req, french.mail });
    try testing.expectEqualStrings("Ce champ est requis", result2.?);

    // Second fails - should get French message
    const result3 = all("notanemail", .{ french.req, french.mail });
    try testing.expectEqualStrings("Adresse e-mail invalide", result3.?);
}

// =============================================================================
// Error Code Tests (Level 3: Programmatic Handling)
// =============================================================================

test "error codes for programmatic handling" {
    const testing = std.testing;

    try testing.expectEqual(ErrorCode.required, requiredCode("").?);
    try testing.expect(requiredCode("hello") == null);

    try testing.expectEqual(ErrorCode.invalid_email, emailCode("invalid").?);
    try testing.expect(emailCode("test@example.com") == null);

    try testing.expectEqual(ErrorCode.min_length, minLengthCode("ab", 3).?);
    try testing.expect(minLengthCode("abc", 3) == null);

    try testing.expectEqual(ErrorCode.mismatch, matchesCode("a", "b").?);
    try testing.expect(matchesCode("a", "a") == null);
}

// =============================================================================
// Structured Result Tests (Level 4: Full A11y Control)
// =============================================================================

test "structured result with accessible message" {
    const testing = std.testing;

    const result = requiredResult("", .{
        .message = "Required",
        .accessible_message = "The username field is required. Please enter a username.",
    });

    try testing.expect(result != null);
    try testing.expectEqual(ErrorCode.required, result.?.code);
    try testing.expectEqualStrings("Required", result.?.displayMessage());
    try testing.expectEqualStrings("The username field is required. Please enter a username.", result.?.screenReaderMessage());
}

test "structured result without accessible message falls back" {
    const testing = std.testing;

    const result = requiredResult("", .{
        .message = "This field is required",
    });

    try testing.expect(result != null);
    // screenReaderMessage should fall back to displayMessage
    try testing.expectEqualStrings("This field is required", result.?.screenReaderMessage());
}

test "structured result returns null for valid input" {
    const testing = std.testing;

    const result = requiredResult("valid", .{
        .message = "Required",
    });

    try testing.expect(result == null);
}

test "emailResult structured" {
    const testing = std.testing;

    const result = emailResult("invalid", .{
        .message = "Invalid email",
        .accessible_message = "Please enter a valid email address",
    });

    try testing.expect(result != null);
    try testing.expectEqual(ErrorCode.invalid_email, result.?.code);
    try testing.expectEqualStrings("Invalid email", result.?.displayMessage());
    try testing.expectEqualStrings("Please enter a valid email address", result.?.screenReaderMessage());
}

test "matchesResult structured" {
    const testing = std.testing;

    const result = matchesResult("password1", "password2", .{
        .message = "Passwords don't match",
        .accessible_message = "The password and confirm password fields must match",
    });

    try testing.expect(result != null);
    try testing.expectEqual(ErrorCode.mismatch, result.?.code);
}
