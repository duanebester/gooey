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

const ui_impl = @import("ui.zig");

// Re-export types
pub const Builder = ui_impl.Builder;

// Primitives
pub const text = ui_impl.text;
pub const textFmt = ui_impl.textFmt;
pub const input = ui_impl.input;
pub const spacer = ui_impl.spacer;
pub const spacerMin = ui_impl.spacerMin;
pub const empty = ui_impl.empty;
pub const keyContext = ui_impl.keyContext;
pub const onAction = ui_impl.onAction;
pub const when = ui_impl.when;

// Primitive types
pub const Text = ui_impl.Text;
pub const Input = ui_impl.Input;
pub const Spacer = ui_impl.Spacer;
pub const Empty = ui_impl.Empty;
pub const KeyContextPrimitive = ui_impl.KeyContextPrimitive;
pub const ActionHandlerPrimitive = ui_impl.ActionHandlerPrimitive;
pub const PrimitiveType = ui_impl.PrimitiveType;

// Styles
pub const Color = ui_impl.Color;
pub const TextStyle = ui_impl.TextStyle;
pub const Box = ui_impl.Box;
pub const StackStyle = ui_impl.StackStyle;
pub const CenterStyle = ui_impl.CenterStyle;
pub const ShadowConfig = ui_impl.ShadowConfig;
pub const InputStyle = ui_impl.InputStyle;
pub const ScrollStyle = ui_impl.ScrollStyle;
