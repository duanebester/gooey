# Accessibility

Gooey 0.4.0 describes its UI to screen readers through fields on elements. A box takes an
optional `a11y` annotation (`ui.A11y`), and a handler asks the screen reader to speak with
`Effects.announce`. There is no push and pop builder and no separate accessibility id: the
box's own `ElementId` and laid-out bounds identify the node.

The public names are:

- `gooey.ui.A11y`: the annotation struct that `ui.Box.a11y` takes.
- `gooey.accessibility.Role`, `gooey.accessibility.State`, and `gooey.accessibility.Live`.
  `gooey.ui.Role` is the same enum as `gooey.accessibility.Role`.

`gooey.accessibility` also declares the framework's tree, bridges, and debug helpers. They
are not pinned by `src/api_check.zig`, and neither is anything in `gooey.internals`, so do
not build on them.

## Contents

- [How it works](#how-it-works)
- [Components that are already accessible](#components-that-are-already-accessible)
- [Making a custom element accessible](#making-a-custom-element-accessible)
- [Announcements and live regions](#announcements-and-live-regions)
- [Roles, states, and live values](#roles-states-and-live-values)
- [Platform bridges](#platform-bridges)
- [Capacity limits](#capacity-limits)
- [Testing](#testing)
- [Known gaps](#known-gaps)
- [References](#references)

## How it works

1. **Build.** When a box with `a11y` is built, its strings are copied into the frame's
   text bytes, so a label may come from a buffer local to the render function.
2. **Emit.** Each box with `a11y` becomes one accessibility node with the box's laid-out
   bounds and its depth among accessible ancestors. `focused` is set when the box holds
   keyboard focus. Boxes without `a11y` add no node and no nesting level, and `ui.text`
   adds no node at all: visible text is not read unless a box around it names it.
3. **Publish.** When a frame is presented, the main thread asks the platform bridge
   whether a screen reader is running. It asks on the first frame and then at most once
   per second of the window's clock (`screen_reader.poll_interval_ns`). When none runs,
   that check is the whole cost. When one runs, the nodes go into a fixed-size tree that
   diffs against the previous frame and hands the bridge only new, changed, and removed
   elements, the frame's announcements, and the focus change.

The tree matches elements across frames by a fingerprint of role, label, parent, and
position among siblings. A changed `label` therefore reads as a new element, not as a
change to the old one. This matters for live regions (see below).

## Components that are already accessible

The `gooey-components` package sets `a11y` for you. Each component that has an
`accessible_name` field uses it as the screen-reader name and otherwise falls back to the
field shown in the table.

| Component    | Role       | Name fallback      | Description field        | Other fields set |
| ------------ | ---------- | ------------------ | ------------------------ | ---------------- |
| `Button`     | `button`   | `label`            | none                     | `disabled`       |
| `Checkbox`   | `checkbox` | `label`            | `accessible_description` | `checked`        |
| `Select`     | `combobox` | `placeholder`      | `accessible_description` | value, expanded  |
| `TextInput`  | `textbox`  | `placeholder`      | `accessible_description` | value (the text) |
| `TextArea`   | `textarea` | `placeholder` only | none                     | value (the text) |
| `CodeEditor` | `textarea` | `placeholder` only | none                     | value (the text) |
| `Modal`      | `dialog`   | `key`              | `accessible_description` | none             |

`TextArea` and `CodeEditor` have no `accessible_name`; `CodeEditor` says "Code editor"
when its placeholder is empty. `Select` also sets `has_popup` and `disabled`, and its value
is the chosen option, or the placeholder when nothing is chosen. Its open menu is a
`listbox` of `option` nodes, each with its label and set position. `List`
adds no node of its own; each row annotates itself. The charts package adds no node
either: `accessible_title`, `accessible_description`, `describe(buf)`, and
`summarize(buf)` produce text, and the app puts that text on a box's `a11y`.

From `src/examples/accessible_form.zig`, a labelled group of buttons:

```zig
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
            Button{
                .label = "Reset",
                .accessible_name = "Reset form to default values",
                .variant = .secondary,
                .size = .large,
                .on_click = cx.on(State.reset, .{}),
            },
        }));
    }
};
```

A text field and a select with names and descriptions, from the same file:

```zig
TextInput{
    .key = "name",
    .bind = &s.name,
    .placeholder = "Enter your full name",
    .accessible_name = "Full name, required field",
    .accessible_description = if (errors.name) "Error: Name is required" else null,
    .width = 300,
    .border_color = if (errors.name) error_color else null,
},
```

```zig
Select{
    .key = "experience",
    .options = &State.experience_options,
    .on_select = &on_select,
    .on_toggle = cx.on(State.toggleExperience, .{}),
    .on_close = cx.on(State.closeExperience, .{}),
    .selected = self.experience_level,
    .open = self.experience_open,
    .placeholder = "Select your experience level",
    // The default 200 is narrower than this placeholder (~202 pt
    // of text) plus padding and the chevron.
    .width = 260,
    .accessible_name = "Experience level",
    .accessible_description = "Select how experienced you are with our products",
},
```

## Making a custom element accessible

Set `a11y` on the box that the user interacts with, so the node's bounds match the click
target. `role` is required; every other field has a default.

| `ui.A11y` field | Type           | Meaning                                            |
| --------------- | -------------- | -------------------------------------------------- |
| `role`          | `Role`         | What the element is. Required.                     |
| `label`         | `?[]const u8`  | The name a screen reader speaks. Part of identity. |
| `value`         | `?[]const u8`  | Current value, such as a field's text or a choice. |
| `description`   | `?[]const u8`  | Help text read after the name.                     |
| `checked`       | `bool`         | A checkbox, radio, or switch is on.                |
| `disabled`      | `bool`         | The element does not respond to input.             |
| `expanded`      | `bool`         | A disclosure, such as a combobox, is open.         |
| `has_popup`     | `bool`         | Activating the element opens a popup.              |
| `heading_level` | `HeadingLevel` | `.none` (default) or `.h1` to `.h6`.               |
| `live`          | `Live`         | How changes inside the element are reported.       |
| `pos_in_set`    | `?u16`         | One-based position among `set_size` siblings.      |
| `set_size`      | `?u16`         | Number of siblings in the set.                     |
| `href`          | `?[]const u8`  | A link target. No bridge reads it yet.             |

A heading, from `src/examples/accessible_form.zig`. The label repeats the visible text
because the `ui.text` child is not read:

```zig
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
```

A clickable header cell exposed as a button, from `src/examples/data_table_example.zig`:

```zig
cx.render(ui.box(.{
    .key = .{ .name = name },
    .on_click = cx.on(State.sortBy, .{ .arg = @as(u32, index) }),
    .a11y = .{ .role = .button, .label = label },
    .style = cell_style(width, header_height),
}, .{ui.text(label, .{ .size = 13, .weight = .semibold, .color = .text })}));
```

A radio option with its state and set position, from `src/examples/accessible_form.zig`
(the visual children are elided):

```zig
cx.render(ui.box(.{
    .key = .{ .name = self.label },
    .style = .{ .direction = .row, .gap = 8, .alignment = .center_cross },
    .on_click = self.on_select,
    .a11y = .{
        .role = .radio,
        .label = self.label,
        .checked = self.selected,
        .pos_in_set = self.pos_in_set,
        .set_size = self.set_size,
    },
}, .{
    // ... the circle and the label text ...
}));
```

The enclosing radio group is a box with `.a11y = .{ .role = .group, .label = self.label }`.

Keyboard access is separate from the annotation. Tab and Shift+Tab move focus in tree
order among boxes with `focusable = true`, skipping those that also set `tab_stop = false`,
which a click or `effects.focus` still focuses and the control's own keys reach, as a
listbox's arrow keys reach its options. Enter or Space clicks the focused box: its
`on_click` runs as a pointer click's would. Both happen only when no `on_key` handler on the
focus path stopped the key, so a text field keeps Space and an editor keeps Tab. A held key's
repeats and Cmd, Ctrl, or Alt chords do not click. A custom control that keyboard users must
reach needs only `focusable = true` beside its `on_click`; the radio options above have both.

While a modal is open, Tab cycles through the modal's controls only, and focus left behind
it is dropped, so a key cannot reach what the pointer cannot.

Focus that the keyboard moved, by Tab or by a handler reacting to a key, draws a focus ring:
2 px of the theme's `border_focus`, 2 px outside the focused box and following its corners.
A pointer press focuses too, but draws no ring, as a browser's `:focus-visible` does. The
keyboard's move also scrolls the innermost scroll box around the focused box, once, so the
box and its ring are in view.

A control with keys of its own, such as `Select`, gives its box an `on_key` handler bound
to state it retained with `cx.retain`, and presses its own parts with `effects.click(id)`,
which runs that element's `on_click`. `Select` keeps focus on the combobox until the menu
opens, then on the highlighted option, so a screen reader follows the highlight:

| Focus on  | Key                     | Does                                              |
| --------- | ----------------------- | ------------------------------------------------- |
| combobox  | Enter, Space, Down, Up  | opens on the selected option, or the first        |
| combobox  | Enter, Space (open)     | closes                                            |
| option    | Down, Up, Home, End     | moves to the next, previous, first, or last       |
| option    | Enter, Space            | chooses it and returns to the combobox            |
| either    | Esc (open)              | closes and returns to the combobox                |
| either    | Tab, Shift+Tab (open)   | closes and moves to the next or previous control  |

## Announcements and live regions

### Announcements

A handler that takes `*Effects` can ask the screen reader to speak. From
`src/examples/accessible_form.zig`, wired with `cx.on(State.submit, .{})`:

```zig
/// Announces the outcome: errors assertively, success politely.
pub fn submit(self: *State, effects: *Effects) void {
    if (self.validate()) {
        self.form_submitted = true;
        self.show_success = true;
        effects.announce("Form submitted successfully!", .polite);
    } else {
        effects.announce("Please fix the errors in the form", .assertive);
    }
}
```

The rules, all asserted or enforced in `src/core/handler.zig` and `src/core/records.zig`:

- The text must not be empty, and the politeness must be `.polite` or `.assertive`.
- One announcement per handler call.
- The text is copied after the handler returns, so point it at a constant or app state,
  not at a buffer on the handler's stack.
- The next built frame carries the announcement, and only that frame.
- Past 16 announcements or 1,024 bytes between two builds the app panics, naming the pool.

`.polite` waits for the screen reader to finish speaking. `.assertive` interrupts it.

### Live regions

An element is a live region when its `live` is `.polite` or `.assertive`. Roles `.alert`
and `.status` are live by default (assertive and polite) even with `live = .off`.

The tree announces a live region when an element it already knows changes its value,
description, or state. It speaks the `value`, or the `label` when there is no value. It
does not announce an element that has just appeared, and since `label` is part of an
element's identity, a changed label counts as a new element. So:

- Keep a live region's `label` fixed and put the changing text in `value`.
- For a message that appears, such as a validation error, also call `effects.announce`
  from the handler that caused it.

`accessible_form` does both. Its error message is an assertive alert:

```zig
/// An assertive live region, so the error is read when it appears.
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
```

The alert appears in the same frame as the `submit` announcement above, which is what the
screen reader speaks.

## Roles, states, and live values

These lists are copied from `src/accessibility/types.zig`.

`Role`:

- Atomic widgets: `button`, `checkbox`, `radio`, `switch_`, `link`.
- Text input: `textbox` (single line), `textarea` (multi-line), `searchbox`, `spinbutton`.
- Selection: `combobox`, `listbox`, `option`, `menu`, `menuitem`, `menubar`.
- Navigation: `tab`, `tablist`, `tabpanel`.
- Disclosure: `tree`, `treeitem`.
- Sliders: `slider`, `scrollbar`.
- Structure: `group`, `region`, `dialog`, `alertdialog`, `toolbar`, `tooltip`.
- Status: `alert`, `status`, `progressbar`.
- Document: `heading`, `paragraph`, `list`, `listitem`, `img`, `separator`.
- Special: `presentation` (explicitly not accessible), `none`.

Each role maps to a platform role in `Role.toNSRole`, `Role.toUiaControlType`, and
`Role.toAriaRole`.

`State` is a 16-bit packed struct: `focused`, `selected`, `checked`, `pressed`, `expanded`,
`disabled`, `readonly`, `required`, `invalid`, `busy`, `hidden`, `has_popup`. The core sets
`focused` from keyboard focus and copies `checked`, `disabled`, `expanded`, and
`has_popup` from `ui.A11y`. `ui.A11y` has no field for the other six, so they are always
false in 0.4.0.

`Live`: `off`, `polite`, `assertive`.

`HeadingLevel` (the type of `ui.A11y.heading_level`): `none`, `h1`, `h2`, `h3`, `h4`, `h5`,
`h6`.

## Platform bridges

All bridges live in `src/accessibility/`.

| Platform | Bridge               | API              | Status                                     |
| -------- | -------------------- | ---------------- | ------------------------------------------ |
| macOS    | `mac_bridge.zig`     | NSAccessibility  | Read-only tree and announcements           |
| Windows  | `windows_bridge.zig` | UI Automation    | Read-only tree and announcements           |
| Web      | `web_bridge.zig`     | Hidden ARIA DOM  | Partial attributes and announcements       |
| Linux    | none                 | none             | No screen-reader support (decision 12)     |

**macOS.** The bridge keeps a pool of `NSAccessibilityElement` objects keyed by
fingerprint. It sets role, label, value (a toggle without a value reports `checked` as 0 or
1), enabled, focused, screen frame, parent, and children. Text fields also answer the
selected range, character count, and line and range queries. It posts focus-changed,
value-changed, and selected-text-changed notifications, and sends announcements with high
priority for `.assertive` and medium for `.polite`. It does not expose `description`,
`heading_level`, `expanded`, `has_popup`, or set positions. It runs only while
`NSWorkspace.isVoiceOverEnabled` is true.

**Windows.** The bridge serves UI Automation providers from a snapshot of the tree. It
exposes control type, name, help text (`description`), focus, enabled, live setting,
heading level, set position and size, ARIA role, bounds in screen pixels, and hit testing.
Patterns by role: Value, Range Value, Toggle, Expand Collapse, and Selection Item.
Announcements are notification events, which need Windows 10 1709. It runs once a client
asks for the root or while `UiaClientsAreListening` is true. See `docs/windows-port.md` for
the full design.

**Web.** The bridge mirrors the tree into a visually hidden DOM under `#gooey-a11y-root`
with ARIA roles. It sets `aria-label`, the state attributes (`aria-checked`,
`aria-disabled`, `aria-expanded`, `aria-haspopup`, and the others from `State`), bounds,
and DOM focus, and speaks announcements through a live region. It does not set the value,
`description`, heading level, `live`, or set positions. The web host always reports a
screen reader as present, so the tree is published on every frame.

**Linux.** There is no bridge. The AT-SPI bridge never joined the accessibility bus, so it
was removed rather than kept as a stub. Frames still record accessibility nodes (the tests
read them), but nothing is published, and Orca cannot see a Gooey app.

No bridge supports actions. A screen reader cannot press, toggle, set a value, expand, or
move focus through the accessibility API; users fall back to the keyboard and pointer.

## Capacity limits

| Limit                           | Value                          | Past the limit              |
| ------------------------------- | ------------------------------ | --------------------------- |
| `build.element_count_frame_max` | 512 to 16,383 by profile       | Panics: pool "a11y nodes"   |
| `build.text_bytes_frame_max`    | 16 KiB to 4 MiB by profile     | Panics: pool "text bytes"   |
| `MAX_ELEMENTS`                  | 2,048 tree elements            | Panics: tree full           |
| `MAX_DEPTH`                     | 64 nested accessible boxes     | Panics: tree full           |
| `Announcements.count_max`       | 16 between two builds          | Panics: announcement pool   |
| `Announcements.bytes_max`       | 1,024 bytes between two builds | Panics: announcement pool   |
| `MAX_ANNOUNCEMENTS`             | 8 per published frame          | The rest are dropped        |
| `poll_interval_ns`              | 1 s                            | None: it is the poll period |

Where they are declared:

- `build.*` are fields of the app's `ResourceLimits` (`src/core/limits.zig`). By profile,
  `nano`, `small`, `standard`, `large`, and `ceiling`: elements 512, 2,048, 4,096, 16,383,
  and 16,383; text bytes 16 KiB, 64 KiB, 256 KiB, 1 MiB, and 4 MiB. Accessibility nodes
  share the frame's element capacity, and their strings share its text bytes.
- `MAX_ELEMENTS`, `MAX_DEPTH`, and `MAX_ANNOUNCEMENTS` are in
  `src/accessibility/constants.zig`.
- `Announcements.count_max` and `bytes_max` are in `src/core/records.zig`.
- `poll_interval_ns` is in `src/core/screen_reader.zig`.

The tree's 2,048 elements are fixed, not a profile field. From `standard` up, a frame may
hold more elements than the tree, so an app with more than 2,048 accessible boxes in one
frame panics as soon as a screen reader runs. The tree check applies only while one runs.

The 8 forwarded announcements include those the tree makes for live regions; the
explicit announcements are queued first.

The Windows bridge adds its own bounds (`windows_snapshot.zig`, `windows_provider.zig`):
`name_bytes_max` 256, `value_bytes_max` 512, and `description_bytes_max` 256, truncated at
a code point boundary; `change_count_max` 128 property events per frame, past which it
invalidates the whole tree; and `provider_count_max` 4,096 providers, past which it
returns `E_OUTOFMEMORY` to the client and warns once instead of panicking, because the
demand comes from another process.

## Testing

### Manual checklist

- Every control a pointer user can operate has a role and a spoken name.
- Visible text that matters is named by an enclosing box's `label`.
- `checked`, `disabled`, and `expanded` follow the same state that draws the control.
- Headings use `heading_level`, and groups of related controls use `.group`.
- Errors and results are announced when they appear.
- Tab reaches every control in a sensible order, and Enter or Space operates it.
- The focus ring shows where keyboard focus is on every theme the app offers.
- Color is not the only signal of state or error.

### Screen readers

Run the form with `zig build run-accessible-form` on macOS or Windows.

- **macOS, VoiceOver.** Toggle with Cmd+F5. VO is Control+Option: VO+arrows move, VO+Space
  activates, VO+U opens the rotor. VoiceOver ignores synthetic key events, so step through
  by hand.
- **Windows, Narrator or NVDA.** Start Narrator with Ctrl+Win+Enter. So far the tree has
  been checked only with the .NET `UIAutomationClient` from PowerShell, not with Narrator
  or NVDA.
- **Web.** `zig build wasm` builds the todo example for the browser. Inspect
  `#gooey-a11y-root` in the browser's accessibility panel, or use VoiceOver or NVDA in the
  browser.
- **Linux.** There is nothing to test with Orca.

### In-repo tests

`zig build test` runs these, among others:

- `src/testing/goldens/core_checks.zig`, "accessible_form validates, announces, and
  submits on the core": drives the form through the router and checks roles, names,
  descriptions, set positions, `checked` and `expanded`, the assertive announcement, and
  the success alert.
- The same file, "setTheme reaches the next build and announcements ride exactly one
  frame": checks that an announcement is carried by exactly one frame and that
  `heading_level`, `live`, and `href` reach the rendered frame.
- The golden files in `src/testing/goldens/` print an `a11y` section after each step with
  every node's role, bounds, and name. `zig build goldens` rewrites them.
- `src/accessibility/` has unit and integration tests for the tree, fingerprints, and
  bridges; `zig build test-windows` covers the Windows snapshot, providers, and bridge.
- `zig build bench-accessibility` runs the accessibility benchmarks.

These tests read the rendered frame through `gooey.internals`, which is fine for tests in
this repository but is not API.

## Known gaps

- Only the innermost scroll box scrolls to keyboard focus, and only when focus moves: a
  focused control that a layout change pushes out of view stays there.
- Focus on an element that stops rendering, such as a deleted row's button, is dropped, and
  the next Tab starts from the first control.
- Arrow keys do not move between radio options; each option is its own Tab stop.
- `Select` has no type-ahead, and choosing an option with the pointer blurs it, as before.
- An option's chosen state is not exported: `ui.A11y` has no `selected` field (see below).
- No bridge supports actions (press, toggle, set value, expand, focus).
- Linux has no screen-reader support (contract decision 12).
- macOS: VoiceOver reports a 0x0 frame for many elements, including headings and radio
  buttons. It does not read plain arrow or Option+arrow caret moves in a `TextInput`,
  because the bridge lacks per-character bounds and text attributes.
- Windows: not yet tried with Narrator or NVDA. Text fields expose only the Value pattern;
  relationships and selection containers are not exposed.
- Web: value, `description`, heading level, and set positions are not exported, and no
  web build of `accessible_form` exists.
- `href` reaches the rendered frame but no bridge reads it.
- `State.selected`, `pressed`, `readonly`, `required`, `invalid`, `busy`, and `hidden` have
  no `ui.A11y` field, so the core never sets them.
- There is no public query for whether a screen reader is running (contract C8, deferred).
- The todo example's row checkbox has no name.

## References

- [WAI-ARIA 1.2](https://www.w3.org/TR/wai-aria-1.2/)
- [ARIA Authoring Practices Guide](https://www.w3.org/WAI/ARIA/apg/)
- [Apple Accessibility](https://developer.apple.com/documentation/accessibility)
- [UI Automation](https://learn.microsoft.com/en-us/windows/win32/winauto/entry-uiauto-win32)
- [WCAG](https://www.w3.org/WAI/standards-guidelines/wcag/)
