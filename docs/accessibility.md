# Gooey Accessibility (A11Y) Documentation

Gooey provides built-in accessibility support for assistive technologies including screen readers (VoiceOver, Orca, NVDA) and other assistive tools. This document covers the architecture, API, and best practices for building accessible applications.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Core Concepts](#core-concepts)
- [Built-in Component Support](#built-in-component-support)
- [Custom Accessible Elements](#custom-accessible-elements)
- [Live Regions & Announcements](#live-regions--announcements)
- [Platform Bridges](#platform-bridges)
- [Making Custom Components Accessible](#making-custom-components-accessible)
- [Testing Accessibility](#testing-accessibility)
- [Performance](#performance)
- [API Reference](#api-reference)

---

## Overview

Gooey's accessibility system provides:

- **Semantic roles** - Describe what an element IS (button, checkbox, heading, etc.)
- **States** - Track element state (focused, checked, disabled, expanded, etc.)
- **Names & descriptions** - Human-readable labels for screen readers
- **Live regions** - Announce dynamic content changes
- **Platform integration** - Native bridges for macOS (VoiceOver), Linux (AT-SPI2/Orca), and Web (ARIA)

### Design Principles

1. **Zero allocation after init** - Static pools for predictable performance
2. **Fingerprint-based identity** - Elements maintain identity across frames without manual IDs
3. **Immediate mode compatible** - Works naturally with Gooey's immediate mode rendering
4. **Built-in by default** - Standard components have accessibility built-in

---

## Quick Start

### Using Built-in Components

All standard Gooey components have built-in accessibility. Simply use the `accessible_name` field to customize what screen readers announce:

```zig
const Button = gooey.Button;
const Checkbox = gooey.Checkbox;

// Button with custom accessible name
Button{
    .label = "+",
    .accessible_name = "Increase counter",  // VoiceOver reads this
    .on_click_handler = handler,
}

// Checkbox - label is used by default
Checkbox{
    .id = "notifications",
    .checked = state.notifications_enabled,
    .label = "Enable notifications",
    // accessible_name defaults to label
}
```

### Adding Accessibility to Custom Elements

For custom UI elements, use `b.accessible()`:

```zig
fn renderCustomWidget(b: *ui.Builder) void {
    // Push accessible element BEFORE the visual element
    if (b.accessible(.{
        .role = .button,
        .name = "Custom action",
        .state = .{ .disabled = is_disabled },
    })) {
        defer b.accessibleEnd();
    }

    // Visual rendering
    b.box(.{ ... }, .{ ... });
}
```

### Announcements

Announce dynamic changes to screen reader users:

```zig
// Non-urgent update (announced when idle)
b.announce("3 items selected", .polite);

// Critical alert (interrupts current speech)
b.announce("Error: Connection lost!", .assertive);
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Code                         │
│                                                             │
│   Button{ .label = "+", .accessible_name = "Increase" }     │
│                           │                                 │
│   b.accessible(.{ .role = .button, .name = "Save" })        │
└───────────────────────────┼─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Accessibility Tree                        │
│                                                             │
│   • Elements with roles, states, names                      │
│   • Fingerprint-based identity (stable across frames)       │
│   • Dirty detection for efficient updates                   │
│   • Static allocation (MAX_ELEMENTS = 2048)                 │
└───────────────────────────┼─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                     Platform Bridge                          │
│                                                             │
│   macOS: NSAccessibility → VoiceOver                        │
│   Linux: AT-SPI2 D-Bus → Orca/NVDA                          │
│   Web:   ARIA attributes → Screen readers                   │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | File | Purpose |
|-----------|------|---------|
| `Tree` | `src/accessibility/tree.zig` | Maintains accessibility element hierarchy |
| `Element` | `src/accessibility/element.zig` | Single accessible element with properties |
| `Fingerprint` | `src/accessibility/fingerprint.zig` | Stable identity for cross-frame correlation |
| `Bridge` | `src/accessibility/bridge.zig` | Platform-agnostic bridge interface |
| `MacBridge` | `src/accessibility/mac_bridge.zig` | macOS VoiceOver integration |
| `LinuxBridge` | `src/accessibility/linux_bridge.zig` | Linux AT-SPI2 integration |
| `WebBridge` | `src/accessibility/web_bridge.zig` | Web ARIA integration |

---

## Core Concepts

### Roles

Roles describe what an element IS semantically. Use the most specific role that applies:

```zig
const Role = enum {
    // Interactive widgets
    button,      // Clickable button
    checkbox,    // Toggle on/off
    radio,       // One of many options
    switch_,     // Toggle switch
    link,        // Navigation link

    // Text input
    textbox,     // Single-line input
    textarea,    // Multi-line input
    searchbox,   // Search field
    spinbutton,  // Numeric input

    // Selection
    combobox,    // Dropdown select
    listbox,     // List of options
    option,      // Single option
    menu,        // Menu container
    menuitem,    // Menu item

    // Navigation
    tab,         // Tab button
    tablist,     // Tab container
    tabpanel,    // Tab content

    // Structure
    group,       // Generic grouping
    region,      // Landmark region
    dialog,      // Modal dialog
    heading,     // Section heading (use with heading_level)
    list,        // List container
    listitem,    // List item

    // Status
    alert,       // Important message (announced immediately)
    status,      // Status information
    progressbar, // Progress indicator

    // Special
    img,         // Image
    presentation,// Explicitly NOT accessible
    none,        // Inherit from context
};
```

### States

States track the current condition of an element:

```zig
const State = packed struct(u16) {
    focused: bool = false,    // Has keyboard focus
    selected: bool = false,   // Selected in collection
    checked: bool = false,    // Checkbox/radio/switch is on
    pressed: bool = false,    // Toggle button is pressed
    expanded: bool = false,   // Disclosure is open
    disabled: bool = false,   // Non-interactive
    readonly: bool = false,   // Value cannot be changed
    required: bool = false,   // Form field is required
    invalid: bool = false,    // Validation failed
    busy: bool = false,       // Async operation in progress
    hidden: bool = false,     // Not visible (skip in a11y tree)
};
```

### Fingerprints

Fingerprints provide stable identity for elements across frames without manual IDs:

```zig
// Fingerprint computed from:
// - Role (6 bits)
// - Parent contribution (16 bits)
// - Position in parent (16 bits)
// - Name hash (26 bits)

const Fingerprint = packed struct(u64) {
    role: u6,
    parent_contrib: u16,
    position: u16,
    name_hash: u26,
};
```

This allows the accessibility system to:
- Detect which elements changed between frames
- Only sync dirty elements to the platform
- Maintain focus across re-renders

---

## Built-in Component Support

All standard Gooey components have accessibility built-in:

| Component | Role | Key States | Notes |
|-----------|------|------------|-------|
| `Button` | `button` | `disabled` | Use `accessible_name` to override label |
| `Checkbox` | `checkbox` | `checked` | Label used as accessible name |
| `TextInput` | `textbox` | - | Placeholder used as fallback name |
| `TextArea` | `textarea` | - | Multi-line text input |
| `Select` | `combobox` | `expanded`, `disabled` | Selected value exposed |
| `Tab` | `tab` | `selected` | Includes `pos_in_set`, `set_size` |
| `TabBar` | `tablist` | - | Container for tabs |
| `RadioGroup` | `radiogroup` | - | Groups radio buttons |
| `ProgressBar` | `progressbar` | - | Exposes value, min, max |
| `Modal` | `dialog` | - | Modal dialog |
| `Tooltip` | `tooltip` | - | Contextual help |

### Example: Accessible Form

```zig
fn renderForm(cx: *Cx) void {
    const s = cx.state(FormState);
    const b = cx.builder();

    // Form heading
    if (b.accessible(.{ .role = .heading, .name = "Contact Form", .heading_level = 1 })) {
        defer b.accessibleEnd();
    }
    cx.text("Contact Form", .{ .size = 24, .weight = .bold });

    // Name field
    gooey.TextInput{
        .id = "name",
        .placeholder = "Your name",
        .accessible_name = "Full name",
        .bind = &s.name,
    };

    // Email field
    gooey.TextInput{
        .id = "email",
        .placeholder = "email@example.com",
        .accessible_name = "Email address",
        .bind = &s.email,
    };

    // Subscribe checkbox
    gooey.Checkbox{
        .id = "subscribe",
        .checked = s.subscribe,
        .label = "Subscribe to newsletter",
        .on_click_handler = cx.update(FormState, FormState.toggleSubscribe),
    };

    // Submit button
    gooey.Button{
        .label = "Send",
        .accessible_name = "Submit contact form",
        .enabled = s.isValid(),
        .on_click_handler = cx.update(FormState, FormState.submit),
    };
}
```

---

## Custom Accessible Elements

### Basic Pattern

```zig
fn renderCustomElement(b: *ui.Builder) void {
    // 1. Push accessible element FIRST
    const a11y_pushed = b.accessible(.{
        .role = .button,
        .name = "Action name",
    });
    defer if (a11y_pushed) b.accessibleEnd();

    // 2. Render visual element
    b.box(.{ ... }, .{ ... });
}
```

### With Layout ID (for bounds tracking)

```zig
const layout_mod = @import("layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

fn renderTrackedElement(b: *ui.Builder, id: []const u8) void {
    const layout_id = LayoutId.fromString(id);

    const a11y_pushed = b.accessible(.{
        .layout_id = layout_id,  // Links to visual element bounds
        .role = .button,
        .name = "Tracked button",
    });
    defer if (a11y_pushed) b.accessibleEnd();

    b.boxWithId(id, .{ ... }, .{ ... });
}
```

### Complex Widget Example

```zig
fn renderSlider(b: *ui.Builder, value: f32, min: f32, max: f32) void {
    const layout_id = LayoutId.fromString("volume-slider");

    const a11y_pushed = b.accessible(.{
        .layout_id = layout_id,
        .role = .slider,
        .name = "Volume",
        .value_min = min,
        .value_max = max,
        .value_now = value,
    });
    defer if (a11y_pushed) b.accessibleEnd();

    // Visual slider rendering...
}
```

---

## Live Regions & Announcements

### Types of Live Regions

| Priority | Use Case | Behavior |
|----------|----------|----------|
| `.off` | No announcements | Default for most elements |
| `.polite` | Non-urgent updates | Announced after current speech |
| `.assertive` | Critical alerts | Interrupts current speech |

### Explicit Announcements

```zig
// Status update (polite)
b.announce("File saved successfully", .polite);

// Error alert (assertive)
b.announce("Connection lost! Please check your network.", .assertive);

// Progress update
b.announce("Upload 75% complete", .polite);
```

### Live Region Elements

For content that changes regularly:

```zig
// Status bar that updates automatically
if (b.accessible(.{
    .role = .status,
    .name = status_message,
    .live = .polite,  // Announce when content changes
})) {
    defer b.accessibleEnd();
}
cx.text(status_message, .{ ... });

// Alert that appears
if (show_error) {
    if (b.accessible(.{
        .role = .alert,
        .name = error_message,
        .live = .assertive,  // Immediate announcement
    })) {
        defer b.accessibleEnd();
    }
    cx.box(.{ .background = Color.red }, .{
        cx.text(error_message, .{ ... }),
    });
}
```

---

## Platform Bridges

### macOS (VoiceOver)

The macOS bridge creates `NSAccessibilityElement` objects and posts notifications:

- **Sync**: Dirty elements synced via NSAccessibility API
- **Announcements**: Posted via `NSAccessibilityAnnouncementRequestedNotification`
- **Focus**: `NSAccessibilityFocusedUIElementChangedNotification`
- **Detection**: Checks for VoiceOver via `AXIsVoiceOverRunning()`

**Testing with VoiceOver:**
1. Enable: `Cmd+F5` or System Settings → Accessibility → VoiceOver
2. Navigate: `Tab` for focus, `VO+arrows` for reading
3. Actions: `VO+Space` to activate

### Linux (AT-SPI2/Orca)

The Linux bridge exposes elements via D-Bus AT-SPI2 protocol:

- **Bus**: Registers on session bus as AT-SPI2 provider
- **Objects**: Each element gets a D-Bus object path
- **Signals**: Property changes, state changes, focus events
- **Detection**: Queries AT-SPI2 registry daemon

**Testing with Orca:**
1. Install: `sudo apt install orca`
2. Enable: `Super+Alt+S` or run `orca`
3. Navigate: `Tab`, `Arrow keys`, `Orca+H` for help

### Web (ARIA)

The Web bridge creates a hidden ARIA tree that screen readers can access:

- **Container**: Off-screen container with `aria-hidden="false"`
- **Elements**: DOM elements with ARIA roles and attributes
- **Updates**: Batched DOM mutations for performance
- **Announcements**: Live region elements

**Testing:**
1. Use browser DevTools → Accessibility tab
2. Test with NVDA (Windows), VoiceOver (macOS), Orca (Linux)
3. Verify with axe-core or Lighthouse

---

## Making Custom Components Accessible

### Step-by-Step Guide

1. **Choose the right role** - Pick the most semantically accurate role
2. **Provide a name** - Concise, descriptive label
3. **Track state** - Expose relevant states (checked, expanded, etc.)
4. **Handle focus** - Ensure keyboard navigation works
5. **Test** - Verify with actual screen readers

### Template

```zig
pub const MyWidget = struct {
    id: []const u8,
    label: []const u8,
    
    // Widget state
    is_active: bool = false,
    enabled: bool = true,
    
    // Interaction
    on_click_handler: ?HandlerRef = null,
    
    // Accessibility overrides
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    pub fn render(self: MyWidget, b: *ui.Builder) void {
        const layout_id = LayoutId.fromString(self.id);

        // Push accessible element
        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .button,  // Choose appropriate role
            .name = self.accessible_name orelse self.label,
            .description = self.accessible_description,
            .state = .{
                .pressed = self.is_active,
                .disabled = !self.enabled,
            },
        });
        defer if (a11y_pushed) b.accessibleEnd();

        // Visual rendering
        b.boxWithId(self.id, .{
            .on_click_handler = if (self.enabled) self.on_click_handler else null,
            // ... styling ...
        }, .{
            ui.text(self.label, .{ ... }),
        });
    }
};
```

### Common Patterns

#### Toggle/Switch

```zig
.role = .switch_,
.state = .{ .checked = is_on },
```

#### Expandable Section

```zig
// Header
.role = .button,
.state = .{ .expanded = is_open },

// Content panel
.role = .region,
.state = .{ .hidden = !is_open },
```

#### Tab Panel

```zig
// Tab button
.role = .tab,
.state = .{ .selected = is_active },
.pos_in_set = tab_index + 1,  // 1-based
.set_size = total_tabs,

// Tab container
.role = .tablist,

// Tab content
.role = .tabpanel,
```

#### Progress/Loading

```zig
.role = .progressbar,
.value_min = 0,
.value_max = 100,
.value_now = progress_percent,
.state = .{ .busy = is_loading },
```

---

## Testing Accessibility

### Manual Testing Checklist

- [ ] All interactive elements are keyboard accessible
- [ ] Focus order is logical
- [ ] Screen reader announces element roles correctly
- [ ] State changes are announced (checked, expanded, etc.)
- [ ] Error messages are announced immediately
- [ ] Images have alt text
- [ ] Headings create logical document structure
- [ ] Color is not the only indicator of state

### Screen Reader Testing

**macOS VoiceOver:**
```bash
# Enable/disable VoiceOver
Cmd+F5

# VoiceOver commands
VO = Control+Option
VO+A       # Read all
VO+Arrows  # Navigate
VO+Space   # Activate
VO+U       # Rotor (element lists)
```

**Linux Orca:**
```bash
# Enable/disable
Super+Alt+S

# Commands
Orca+H     # Help
Tab        # Navigate
Enter      # Activate
```

### Debugging Tools

Use the accessibility tree dump for debugging:

```zig
// In debug builds, dump the a11y tree
if (builtin.mode == .Debug) {
    const tree = gooey.a11y_tree;
    for (tree.elements[0..tree.element_count]) |elem| {
        std.debug.print("Role: {s}, Name: {s}\n", .{
            @tagName(elem.role),
            elem.name orelse "(none)",
        });
    }
}
```

---

## Performance

### Budget

| Metric | Target |
|--------|--------|
| Tree construction (100 elements) | < 50μs |
| Dirty detection (100 elements) | < 10μs |
| Fingerprint computation | < 100ns |
| macOS sync (10 dirty) | < 500μs |
| Linux D-Bus sync (10 dirty) | < 2ms |
| Web DOM sync (10 dirty) | < 1ms |
| Memory overhead | < 500KB |

### Limits

```zig
// src/accessibility/constants.zig
pub const MAX_ELEMENTS = 2048;        // Max elements per frame
pub const MAX_DEPTH = 64;             // Max nesting depth
pub const MAX_ANNOUNCEMENTS = 8;      // Max announcements per frame
pub const MAX_DIRTY_SYNC_PER_FRAME = 64;  // Max dirty syncs per frame
```

### Best Practices

1. **Use built-in components** - They're already optimized
2. **Avoid deep nesting** - Keep tree depth reasonable
3. **Batch announcements** - Don't spam live regions
4. **Use fingerprints** - Let the system handle identity
5. **Check `isA11yEnabled()`** - Skip expensive a11y work when disabled

---

## API Reference

### Builder Methods

```zig
/// Begin an accessible element
/// Returns true if a11y is enabled and element was pushed
pub fn accessible(self: *Builder, config: AccessibleConfig) bool

/// End current accessible element
pub fn accessibleEnd(self: *Builder) void

/// Announce a message to screen readers
pub fn announce(self: *Builder, message: []const u8, priority: Live) void

/// Check if accessibility is enabled
pub fn isA11yEnabled(self: *Builder) bool
```

### AccessibleConfig

```zig
pub const AccessibleConfig = struct {
    // Identity
    layout_id: ?LayoutId = null,
    
    // Semantics
    role: Role = .none,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value: ?[]const u8 = null,
    
    // State
    state: State = .{},
    live: Live = .off,
    heading_level: ?HeadingLevel = null,
    
    // Range values (for sliders, progress bars)
    value_min: ?f32 = null,
    value_max: ?f32 = null,
    value_now: ?f32 = null,
    
    // Set position (for tabs, list items)
    pos_in_set: ?u16 = null,
    set_size: ?u16 = null,
};
```

### Role Enum

See [Roles](#roles) section above.

### State Struct

See [States](#states) section above.

### Live Enum

```zig
pub const Live = enum(u2) {
    off = 0,       // No announcements
    polite = 1,    // Announce when idle
    assertive = 2, // Interrupt immediately
};
```

---

## References

- [WAI-ARIA 1.2 Specification](https://www.w3.org/TR/wai-aria-1.2/)
- [ARIA Authoring Practices Guide](https://www.w3.org/WAI/ARIA/apg/)
- [Apple Accessibility Programming Guide](https://developer.apple.com/documentation/accessibility)
- [AT-SPI2 Documentation](https://docs.gtk.org/atspi2/)
- [Web Content Accessibility Guidelines (WCAG)](https://www.w3.org/WAI/standards-guidelines/wcag/)
