//! Modal Component
//!
//! A dialog overlay with backdrop, focus trapping, and keyboard dismissal.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.
//!
//! The modal renders a full-viewport overlay with a centered content container.
//! Features include:
//! - Click-outside to dismiss (optional)
//! - Escape key to close (handled at app level)
//! - Animated fade in/out with scale effect
//!
//! ## Usage
//!
//! ```zig
//! Modal(ConfirmDialogContent){
//!     .id = "confirm-dialog",
//!     .is_open = s.show_confirm,
//!     .on_close = cx.update(State, State.closeConfirm),
//!     .child = ConfirmDialogContent{
//!         .message = "Are you sure?",
//!         .on_confirm = cx.update(State, State.doConfirm),
//!     },
//! }
//! ```

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const HandlerRef = ui.HandlerRef;
const ShadowConfig = ui.ShadowConfig;
const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;
const animation_mod = @import("../animation/mod.zig");
const Easing = animation_mod.Easing;
const AnimationHandle = animation_mod.AnimationHandle;

/// Creates a Modal component that displays a dialog overlay.
/// The modal renders on top of all other content when `is_open` is true.
pub fn Modal(comptime ChildType: type) type {
    return struct {
        /// Unique identifier for the modal (used for animation and dispatch)
        id: []const u8,

        /// Whether the modal is currently visible
        is_open: bool,

        /// Handler called when modal should close (backdrop click, escape key)
        on_close: ?HandlerRef = null,

        /// The content to display inside the modal
        child: ChildType,

        // === Behavior ===

        /// Close modal when clicking the backdrop
        close_on_backdrop: bool = true,

        // === Animation ===

        /// Enable enter/exit animations
        animate: bool = true,

        /// Animation duration in milliseconds
        animation_duration_ms: u32 = 200,

        // === Styling (null = use theme) ===

        /// Backdrop overlay color (semi-transparent black by default)
        backdrop_color: ?Color = null,

        /// Maximum width of the content container (null = no limit)
        content_max_width: ?f32 = 500,

        /// Padding inside the content container
        content_padding: f32 = 24,

        /// Background color of the content container
        content_background: ?Color = null,

        /// Corner radius of the content container (null = use theme)
        content_corner_radius: ?f32 = null,

        /// Shadow around the content container
        content_shadow: ?ShadowConfig = ShadowConfig{
            .offset_x = 0,
            .offset_y = 8,
            .blur_radius = 24,
            .color = Color.rgba(0, 0, 0, 0.25),
        },

        // Accessibility overrides
        accessible_name: ?[]const u8 = null,
        accessible_description: ?[]const u8 = null,

        const Self = @This();

        pub fn render(self: Self, b: *ui.Builder) void {
            const t = b.theme();

            // Resolve colors: explicit value OR theme default
            const backdrop = self.backdrop_color orelse Color.rgba(0, 0, 0, 0.5);
            const background = self.content_background orelse t.surface;
            const radius = self.content_corner_radius orelse t.radius_lg;

            // Get animation state through Builder's Gooey reference
            const anim: AnimationHandle = blk: {
                if (!self.animate) {
                    break :blk if (self.is_open) AnimationHandle.complete else AnimationHandle.idle;
                }

                const g = b.getGooey() orelse {
                    // Fallback if no Gooey available
                    break :blk if (self.is_open) AnimationHandle.complete else AnimationHandle.idle;
                };

                // Hash the trigger value (is_open bool)
                const trigger_hash: u64 = if (self.is_open) 1 else 0;

                break :blk g.widgets.animateOn(self.id, trigger_hash, .{
                    .duration_ms = self.animation_duration_ms,
                    .easing = Easing.easeOutCubic,
                });
            };

            // Only render when open or animating out
            if (!self.is_open and !anim.running) return;

            const layout_id = LayoutId.fromString(self.id);

            // Push accessible element (role: dialog)
            const a11y_pushed = b.accessible(.{
                .layout_id = layout_id,
                .role = .dialog,
                .name = self.accessible_name orelse self.id,
                .description = self.accessible_description,
            });
            defer if (a11y_pushed) b.accessibleEnd();

            // Calculate animated values
            const progress = if (self.is_open) anim.progress else 1.0 - anim.progress;

            // Render the modal structure
            b.with(ModalOverlay(ChildType){
                .id = self.id,
                .progress = progress,
                .backdrop_color = backdrop,
                .on_backdrop_click = if (self.close_on_backdrop) self.on_close else null,
                .child = self.child,
                .max_width = self.content_max_width,
                .padding = self.content_padding,
                .background = background,
                .corner_radius = radius,
                .shadow = self.content_shadow,
            });
        }
    };
}

/// Internal: Full-viewport overlay with backdrop
fn ModalOverlay(comptime ChildType: type) type {
    return struct {
        id: []const u8,
        progress: f32,
        backdrop_color: Color,
        on_backdrop_click: ?HandlerRef,
        child: ChildType,
        max_width: ?f32,
        padding: f32,
        background: Color,
        corner_radius: f32,
        shadow: ?ShadowConfig,

        pub fn render(self: @This(), b: *ui.Builder) void {
            // Full viewport overlay
            b.boxWithId(self.id, .{
                // Full viewport via floating with no parent attachment
                .floating = .{
                    .attach_to_parent = false,
                    .element_anchor = .left_top,
                    .parent_anchor = .left_top,
                    .z_index = 1000, // Above most content
                },
                .fill_width = true,
                .fill_height = true,
                // Backdrop with animated opacity
                .background = self.backdrop_color.withAlpha(self.backdrop_color.a * self.progress),
                // Center the content
                .alignment = .{ .main = .center, .cross = .center },
                // Backdrop click handler
                .on_click_handler = self.on_backdrop_click,
            }, .{
                ModalContent(ChildType){
                    .child = self.child,
                    .progress = self.progress,
                    .max_width = self.max_width,
                    .padding = self.padding,
                    .background = self.background,
                    .corner_radius = self.corner_radius,
                    .shadow = self.shadow,
                },
            });
        }
    };
}

/// Internal: Content container with animation
fn ModalContent(comptime ChildType: type) type {
    return struct {
        child: ChildType,
        progress: f32,
        max_width: ?f32,
        padding: f32,
        background: Color,
        corner_radius: f32,
        shadow: ?ShadowConfig,

        pub fn render(self: @This(), b: *ui.Builder) void {
            // Scale animation: starts at 95% and grows to 100%
            const scale = animation_mod.lerp(0.95, 1.0, self.progress);

            // Calculate scaled dimensions (if max_width is set)
            const scaled_max_width: ?f32 = if (self.max_width) |mw| mw * scale else null;

            b.box(.{
                .max_width = scaled_max_width,
                .padding = .{ .all = self.padding },
                .background = self.background,
                .corner_radius = self.corner_radius,
                .shadow = if (self.shadow) |s| ShadowConfig{
                    .offset_x = s.offset_x,
                    .offset_y = s.offset_y * self.progress, // Rise effect
                    .blur_radius = s.blur_radius,
                    .color = s.color, // Opacity handles alpha
                } else null,
                .opacity = self.progress, // Fades entire subtree including text/buttons
                .direction = .column,
            }, .{
                self.child,
            });
        }
    };
}
