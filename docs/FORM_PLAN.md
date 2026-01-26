Form Validation Implementation Plan

## Overview

Add form validation support to Gooey using the **hybrid approach**: render-time validation with touched tracking via `on_blur_handler`.

---

## Phase 1: Foundation - Add `on_blur_handler` ✅ COMPLETE

**Goal:** Enable components to know when a user has finished interacting with a field.

### 1.1 Add blur detection to TextInput widget ✅

**File:** `src/widgets/text_input_state.zig`

- Added `on_blur: ?*const fn (*TextInput) void = null` callback field
- Invokes callback in `blur()` method when widget was focused

### 1.2 Expose `on_blur_handler` on TextInput component ✅

**File:** `src/components/text_input.zig`

- Added `on_blur_handler: ?HandlerRef = null` field
- Wired through to `InputStyle` in primitive call

### 1.3 Wire up blur handler invocation in runtime ✅

**Files:** `src/context/gooey.zig`, `src/runtime/frame.zig`

- Added `blur_handlers: std.StringHashMap(HandlerRef)` to Gooey for per-field tracking
- Added `registerBlurHandler()`, `clearBlurHandlers()`, `invokeBlurHandlersForFocusedWidgets()`
- `syncWidgetFocus()` and `blurAll()` now invoke blur handlers before blurring
- Frame render registers handlers from pending items each frame

### 1.4 Repeat for TextArea and CodeEditor ✅

**Files modified:**

- `src/widgets/text_area_state.zig` - Added `on_blur` callback
- `src/components/text_area.zig` - Added `on_blur_handler` field
- `src/widgets/code_editor_state.zig` - Added `on_blur` callback
- `src/components/code_editor.zig` - Added `on_blur_handler` field
- `src/ui/styles.zig` - Added `on_blur_handler` to `InputStyle`, `TextAreaStyle`, `CodeEditorStyle`
- `src/ui/builder.zig` - Added `on_blur_handler` to pending structs

**Deliverable:** All text input components support `on_blur_handler` ✅

**Usage:**

```zig
gooey.TextInput{
    .id = "email",
    .bind = &state.email,
    .on_blur_handler = cx.update(State.onEmailBlur),
}
```

---

## Phase 2: Validation Utilities ✅ COMPLETE

**Goal:** Pure, testable validation functions.

### 2.1 Create validation module ✅

**File:** `src/validation.zig` (new)

```/dev/null/validation_api.zig#L1-45
// Core types
pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,
};

pub const FieldResult = ?[]const u8; // null = valid, string = error message

// Common validators (pure functions)
pub fn required(value: []const u8) FieldResult;
pub fn minLength(value: []const u8, min: usize) FieldResult;
pub fn maxLength(value: []const u8, max: usize) FieldResult;
pub fn email(value: []const u8) FieldResult;
pub fn numeric(value: []const u8) FieldResult;
pub fn alphanumeric(value: []const u8) FieldResult;
pub fn matches(value: []const u8, other: []const u8) FieldResult; // For confirm password

// Combinator - run multiple validators
pub fn all(value: []const u8, validators: anytype) FieldResult;

// Form-level helper
pub fn FormErrors(comptime max_fields: usize) type {
    return struct {
        errors: [max_fields]?[]const u8,
        pub fn isValid(self: *const @This()) bool;
        pub fn get(self: *const @This(), index: usize) ?[]const u8;
        pub fn set(self: *@This(), index: usize, err: ?[]const u8) void;
    };
}
```

### 2.2 Add comprehensive tests ✅

- Test each validator in isolation
- Test edge cases (empty strings, unicode, etc.)
- Test combinators

### 2.3 Export from root ✅

**File:** `src/root.zig`

- Add `pub const validation = @import("validation.zig");`

**Deliverable:** `gooey.validation.required()`, etc. available to users ✅

**Implemented validators:**

- `required`, `minLength`, `maxLength`, `email`, `numeric`, `alphanumeric`, `matches`
- `hasUppercase`, `hasLowercase`, `hasDigit`, `hasSpecialChar` (password strength)
- `minLengthValidator`, `maxLengthValidator` (factory functions for `all` combinator)
- `all` combinator for chaining validators
- `FormErrors(max_fields)` for form-level error tracking
- `TouchedFields(max_fields)` for touched state tracking

---

## Phase 3: ValidatedTextInput Component ✅ COMPLETE

**Goal:** Convenient component that bundles label + input + error display.

### 3.1 Create component ✅

**File:** `src/components/validated_text_input.zig` (new)

```/dev/null/validated_input_api.zig#L1-30
pub const ValidatedTextInput = struct {
    // Required
    id: []const u8,

    // Binding
    bind: ?*[]const u8 = null,

    // Validation display
    error: ?[]const u8 = null,        // Error message to show
    touched: bool = true,              // Only show error if touched

    // Labels
    label: ?[]const u8 = null,
    placeholder: []const u8 = "",
    help_text: ?[]const u8 = null,
    required_indicator: bool = false,  // Show * after label

    // Handlers
    on_blur_handler: ?HandlerRef = null,

    // Styling (inherits TextInput defaults)
    width: ?f32 = null,
    // ...

    pub fn render(self: ValidatedTextInput, b: *ui.Builder) void;
};
```

### 3.2 Export from components ✅

**File:** `src/components/mod.zig`

- Add export

**File:** `src/root.zig`

- Add `pub const ValidatedTextInput = components.ValidatedTextInput;`

**Deliverable:** `gooey.ValidatedTextInput` available to users ✅

**Implemented features:**

- `id`, `bind` - required field ID and data binding
- `error_message`, `show_error` - validation error display with touched tracking
- `label`, `placeholder`, `help_text`, `required_indicator` - labels and helper text
- `on_blur_handler` - blur event for touched state tracking
- `secure` - password masking support
- Full styling options: colors, sizes, border states (including error state borders)
- Accessibility: screen reader support with role, name, description, value
- Focus navigation: tab_index, tab_stop

---

## Phase 4: Documentation & Example ✅ COMPLETE

**Goal:** Show developers how to use form validation effectively.

### 4.1 Create form validation example ✅

**File:** `src/examples/form_validation.zig` (new)

Demonstrates:

- Simple form with 3-4 fields
- Per-field touched tracking
- Real-time validation display
- Submit validation
- Form reset
- Both manual pattern and ValidatedTextInput component

### 4.2 Add to build.zig ✅

- Add `zig build run-form-validation`

### 4.3 Update README ✅

**File:** `readme.md`

- Add Form Validation section showing the pattern
- Link to example

**Deliverable:** Working example + documentation ✅

**Implemented:**

- `src/examples/form_validation.zig` - Complete example with:
  - Username/email fields using `ValidatedTextInput`
  - Password/confirm fields using manual pattern (for comparison)
  - Per-field touched tracking with `on_blur_handler`
  - Form submission with full validation
  - Form reset functionality
  - Debug info panel showing state
  - Comprehensive tests
- `build.zig` - Added `run-form-validation` step
- `readme.md` - Added Form Validation section with:
  - Validation utilities API
  - `ValidatedTextInput` usage example
  - Form-level helpers (`FormErrors`, `TouchedFields`)

---

## Phase 5: Polish & Edge Cases ✅ COMPLETE

**Goal:** Enhanced accessibility and focus management for production-ready forms.

### 5.1 Accessibility ✅

**File:** `src/components/validated_text_input.zig`

Implemented:

- `aria-invalid`: Automatically set via `state.invalid` when field has visible error
- `aria-required`: Set via `state.required` when `required_indicator` is true
- `aria-describedby`: Links input to error message element via `described_by_id`
- Live region announcements: Error messages use `role="alert"` with configurable `live` (polite/assertive)
- New field: `error_live_region: a11y.Live = .polite` for customizing announcement urgency

### 5.2 Focus management ✅

**File:** `src/examples/form_validation.zig`

Implemented:

- `getFirstInvalidField()` helper that returns ID of first invalid field
- `pending_focus` state field for deferred focus after submit
- Auto-focus first invalid field when form submission fails
- Uses existing `cx.focusTextField("field-id")` API

### 5.3 Tests ✅

**Files:** `src/components/validated_text_input.zig`, `src/examples/form_validation.zig`

Implemented:

- `generateErrorId` tests for ID generation (normal and long IDs)
- Existing form validation tests cover touched state, validation, reset
- All 730 tests pass

---

## Implementation Order

| Order | Phase                                | Effort | Risk                    |
| ----- | ------------------------------------ | ------ | ----------------------- |
| 1     | Phase 1.1-1.3 (TextInput blur)       | Medium | Low - isolated change   |
| 2     | Phase 2 (Validation utilities)       | Low    | None - pure functions   |
| 3     | Phase 3 (ValidatedTextInput)         | Low    | None - just a component |
| 4     | Phase 1.4 (TextArea/CodeEditor blur) | Low    | None - copy pattern     |
| 5     | Phase 4 (Docs/Example)               | Medium | None                    |
| 6     | Phase 5 (Polish)                     | Low    | None                    |

**Total estimated effort:** ~2-3 focused sessions

---

## Success Criteria

1. ✅ `on_blur_handler` works on TextInput, TextArea, CodeEditor — **DONE**
2. ✅ `gooey.validation.required()` and friends are available — **DONE**
3. ✅ `gooey.ValidatedTextInput` renders label + input + error — **DONE**
4. ✅ Example runs and demonstrates the pattern — **DONE**
5. ✅ README documents form validation — **DONE**
6. ✅ Accessibility: `aria-invalid`, `aria-required`, `aria-describedby`, live regions — **DONE**
7. ✅ Focus management: auto-focus first invalid field on submit — **DONE**

---

## 🎉 FORM VALIDATION IMPLEMENTATION COMPLETE 🎉

All phases successfully implemented. The form validation system provides:

- **Pure validation functions** via `gooey.validation`
- **Touched state tracking** via `on_blur_handler`
- **Convenient component** via `gooey.ValidatedTextInput`
- **Full accessibility support** for screen readers
- **Focus management** for keyboard users
- **Comprehensive documentation** and working example
