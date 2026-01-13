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
const canvas_mod = @import("canvas.zig");

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
pub const codeEditor = primitives.codeEditor;
pub const spacer = primitives.spacer;
pub const spacerMin = primitives.spacerMin;
pub const svg = primitives.svg;
pub const svgIcon = primitives.svgIcon;
pub const empty = primitives.empty;
pub const keyContext = primitives.keyContext;
pub const onAction = primitives.onAction;
pub const onActionHandler = primitives.onActionHandler;
pub const when = primitives.when;
pub const maybe = primitives.maybe;
pub const each = primitives.each;
pub const canvas = canvas_mod.canvas;

// Container element functions (Phase 1: cx/ui separation)
// These return element structs for use with cx.render()
pub const box = primitives.box;
pub const hstack = primitives.hstack;
pub const vstack = primitives.vstack;
pub const scroll = primitives.scroll;

// Tracked variants with source location (Phase 4)
pub const boxTracked = primitives.boxTracked;
pub const hstackTracked = primitives.hstackTracked;
pub const vstackTracked = primitives.vstackTracked;
pub const scrollTracked = primitives.scrollTracked;

// =============================================================================
// Primitive Types
// =============================================================================

pub const Text = primitives.Text;
pub const Input = primitives.Input;
pub const TextAreaPrimitive = primitives.TextAreaPrimitive;
pub const CodeEditorPrimitive = primitives.CodeEditorPrimitive;
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
// Canvas (Custom Drawing)
// =============================================================================

pub const Canvas = canvas_mod.Canvas;
pub const DrawContext = canvas_mod.DrawContext;
pub const CachedPath = canvas_mod.CachedPath;
pub const Path = canvas_mod.Path;
pub const LinearGradient = canvas_mod.LinearGradient;
pub const RadialGradient = canvas_mod.RadialGradient;
pub const Gradient = canvas_mod.Gradient;
pub const LineCap = canvas_mod.LineCap;
pub const LineJoin = canvas_mod.LineJoin;
pub const StrokeStyle = canvas_mod.StrokeStyle;

// =============================================================================
// Styles
// =============================================================================

pub const Color = styles.Color;
pub const TextStyle = styles.TextStyle;
pub const Box = styles.Box;
pub const InputStyle = styles.InputStyle;
pub const TextAreaStyle = styles.TextAreaStyle;
pub const CodeEditorStyle = styles.CodeEditorStyle;
pub const StackStyle = styles.StackStyle;
pub const CenterStyle = styles.CenterStyle;
pub const ScrollStyle = styles.ScrollStyle;
pub const UniformListStyle = styles.UniformListStyle;
pub const VirtualListStyle = styles.VirtualListStyle;
pub const DataTableStyle = styles.DataTableStyle;
pub const ButtonStyle = styles.ButtonStyle;
pub const CheckboxStyle = styles.CheckboxStyle;
pub const ShadowConfig = styles.ShadowConfig;
pub const CornerRadius = styles.CornerRadius;

// =============================================================================
// Drag & Drop
// =============================================================================

pub const Draggable = styles.Draggable;
pub const DropTarget = styles.DropTarget;

// =============================================================================
// Floating Positioning
// =============================================================================

pub const Floating = styles.Floating;
pub const AttachPoint = styles.AttachPoint;

// =============================================================================
// Theme
// =============================================================================

pub const Theme = theme_mod.Theme;

// =============================================================================
// Accessibility (Phase 1)
// =============================================================================

pub const AccessibleConfig = builder_mod.AccessibleConfig;
pub const A11yRole = builder_mod.A11yRole;
pub const A11yState = builder_mod.A11yState;
pub const A11yLive = builder_mod.A11yLive;
