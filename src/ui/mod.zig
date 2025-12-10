//! UI Component System
//!
//! A declarative, component-based UI API for Gooey.
//!
//! Components are structs with a `render` method:
//! ```zig
//! const MyComponent = struct {
//!     value: i32,
//!
//!     pub fn render(self: @This(), b: *ui.Builder) void {
//!         b.box(.{}, .{ ui.text("...", .{}) });
//!     }
//! };
//! ```

const ui_impl = @import("ui.zig");

// Re-export types
pub const Builder = ui_impl.Builder;
pub const HitRegion = ui_impl.HitRegion;

// Primitives
pub const text = ui_impl.text;
pub const textFmt = ui_impl.textFmt;
pub const input = ui_impl.input;
pub const spacer = ui_impl.spacer;
pub const spacerMin = ui_impl.spacerMin;
pub const button = ui_impl.button;
pub const buttonStyled = ui_impl.buttonStyled;
pub const empty = ui_impl.empty;

// Primitive types
pub const Text = ui_impl.Text;
pub const Input = ui_impl.Input;
pub const Spacer = ui_impl.Spacer;
pub const Button = ui_impl.Button;
pub const Empty = ui_impl.Empty;
pub const PrimitiveType = ui_impl.PrimitiveType;

// Styles
pub const Color = ui_impl.Color;
pub const TextStyle = ui_impl.TextStyle;
pub const BoxStyle = ui_impl.BoxStyle;
pub const StackStyle = ui_impl.StackStyle;
pub const CenterStyle = ui_impl.CenterStyle;
pub const ShadowConfig = ui_impl.ShadowConfig;
pub const ButtonStyle = ui_impl.ButtonStyle;
pub const InputStyle = ui_impl.InputStyle;
