//! UI Primitives and Builder
//!
//! Low-level primitives for the UI system. For most uses, prefer
//! the component wrappers in `gooey.components`:
//!
//! ```zig
//! const gooey = @import("gooey");
//!
//! // Components (preferred)
//! gooey.Button{ .label = "Click", .on_click_handler = cx.update(State.onClick) }
//! gooey.Checkbox{ .id = "agree", .checked = state.agreed, .on_click_handler = cx.update(State.toggle) }
//! gooey.TextInput{ .id = "name", .placeholder = "Enter name", .bind = &state.name }
//!
//! // Primitives (for text, spacers, etc.)
//! gooey.ui.text("Hello", .{})
//! gooey.ui.spacer()
//! ```

// =============================================================================
// Internal modules
// =============================================================================

const builder_mod = @import("builder.zig");
const primitives = @import("primitives.zig");
const styles = @import("styles.zig");
const theme_mod = @import("theme.zig");

// =============================================================================
// Builder
// =============================================================================

pub const Builder = builder_mod.Builder;

// =============================================================================
// Primitive Functions
// =============================================================================

pub const text = primitives.text;
pub const textFmt = primitives.textFmt;
pub const input = primitives.input;
pub const textArea = primitives.textArea;
pub const spacer = primitives.spacer;
pub const spacerMin = primitives.spacerMin;
pub const svg = primitives.svg;
pub const svgIcon = primitives.svgIcon;
pub const empty = primitives.empty;
pub const keyContext = primitives.keyContext;
pub const onAction = primitives.onAction;
pub const onActionHandler = primitives.onActionHandler;
pub const when = primitives.when;

// =============================================================================
// Primitive Types
// =============================================================================

pub const Text = primitives.Text;
pub const Input = primitives.Input;
pub const TextAreaPrimitive = primitives.TextAreaPrimitive;
pub const Spacer = primitives.Spacer;
pub const Button = primitives.Button;
pub const ButtonHandler = primitives.ButtonHandler;
pub const Empty = primitives.Empty;
pub const SvgPrimitive = primitives.SvgPrimitive;
pub const ImagePrimitive = primitives.ImagePrimitive;
pub const KeyContextPrimitive = primitives.KeyContextPrimitive;
pub const ActionHandlerPrimitive = primitives.ActionHandlerPrimitive;
pub const ActionHandlerRefPrimitive = primitives.ActionHandlerRefPrimitive;
pub const PrimitiveType = primitives.PrimitiveType;
pub const HandlerRef = primitives.HandlerRef;
pub const ObjectFit = primitives.ObjectFit;

// =============================================================================
// Styles
// =============================================================================

pub const Color = styles.Color;
pub const TextStyle = styles.TextStyle;
pub const Box = styles.Box;
pub const InputStyle = styles.InputStyle;
pub const TextAreaStyle = styles.TextAreaStyle;
pub const StackStyle = styles.StackStyle;
pub const CenterStyle = styles.CenterStyle;
pub const ScrollStyle = styles.ScrollStyle;
pub const ButtonStyle = styles.ButtonStyle;
pub const CheckboxStyle = styles.CheckboxStyle;
pub const ShadowConfig = styles.ShadowConfig;
pub const CornerRadius = styles.CornerRadius;

// =============================================================================
// Floating Positioning
// =============================================================================

pub const Floating = styles.Floating;
pub const AttachPoint = styles.AttachPoint;

// =============================================================================
// Theme
// =============================================================================

pub const Theme = theme_mod.Theme;
