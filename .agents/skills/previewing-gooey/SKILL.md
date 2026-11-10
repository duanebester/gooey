---
name: previewing-gooey
description: Builds and runs Gooey examples in a headless Wayland session and captures reviewable screenshots. Use when asked to run, preview, inspect, or screenshot a Gooey app in an Amp orb, or to test Gooey on GNOME, Wayland, or Linux (input, IME, resize, every example on both Wayland backends).
compatibility: Requires an Amp Linux orb prepared by .agents/setup.
---

# Previewing Gooey

Two workflows, both headless and rendered with Mesa's software Vulkan (llvmpipe):

- **Quick preview:** the todo example under Weston, one screenshot.
- **GNOME check:** a GNOME Shell (mutter) Wayland session with real input, IBus, and
  screenshots, for testing behaviour on Linux.

## Quick preview (Weston)

```bash
.agents/skills/previewing-gooey/scripts/capture-todo
```

The script builds `zig build todo` with the checked-in SPIR-V shaders, starts Weston and Gooey
as supervised orb services, and captures `.amp/in/artifacts/gooey-todo.png`. Pass a
repository-relative output path to choose another name. If the screenshot is blank, check
`amp orb service status gooey-app` and `amp orb service logs gooey-app`. Stop it with
`amp orb service stop gooey-app` and `amp orb service stop gooey-wayland`.

## GNOME check (mutter on Wayland)

```bash
.agents/skills/previewing-gooey/scripts/gnome-session start
.agents/skills/previewing-gooey/scripts/gnome-check        # vulkan | cpu | all (default)
.agents/skills/previewing-gooey/scripts/gnome-session stop
```

`gnome-session start` runs GNOME Shell headless on a 1280x800 virtual monitor
(`--wayland --no-x11`), with a session bus, PipeWire, and WirePlumber, all as orb services.
It adds IBus Anthy as a second input source and writes the client environment to
`/tmp/gnome-rt/env`.

`gnome-check` builds every example for `wayland_vulkan` and `wayland_cpu`. For each one it
launches it, captures a frame, closes it with Alt+F4, and requires exit status 0 and no
panic, assertion, or capacity error on stderr. It then maximizes todo and checks typing,
Backspace, Home and End, Shift, Add, and Japanese input: preedit, conversion, the candidate
window, and commit. It prints `ok` or `FAIL` per check and exits nonzero on any failure.

Screenshots go to `.amp/in/artifacts/gnome/`: one per example, a `vulkan-all.png` and
`cpu-all.png` contact sheet, and `todo-edit.png` and `todo-ime-*.png`. A frame that draws
wrong still passes, so inspect them with `view_media`:

- Every example shows a fully drawn first frame.
- `todo-edit.png` lists "XBuy milk!" and "Walk dog".
- `todo-ime-preedit.png` shows underlined kana, and `todo-ime-candidates.png` shows the
  candidate list directly under the field.

### Driving a session by hand

```bash
source /tmp/gnome-rt/env
./zig-out/bin/gooey-counter > /tmp/counter.log 2>&1 &
.agents/skills/previewing-gooey/scripts/gnome-input \
    "key Super_L+Up; sleep 1; click 640 400; type Hello!; shot /tmp/screen.png"
```

`gnome-input` takes `;`-separated commands: `move X Y`, `click [X Y]`,
`drag X0 Y0 X1 Y1`, `scroll STEPS`, `key A+B`, `down KEY`, `up KEY`, `type TEXT`,
`shot PATH`, and `sleep SECONDS`. Coordinates are screen pixels; GNOME's top bar is 32 px.
Run a short-lived app as a background child, as above, so its exit status stays readable.
Run long-lived servers as orb services.

### What the session cannot show

- **Expected on GNOME:** no title bar, because mutter offers no server-side decorations and
  Gooey draws none. Alt+F4 closes the window.
- **Expected on GNOME 43:** no hover cursor changes. Gooey sets cursors only through
  `wp_cursor_shape_v1`, which mutter added in GNOME 48.
- **Not covered:** hardware GPUs, fractional scaling, and physical displays. Test those on a
  real Linux machine.
- **Fonts differ:** text layout uses the orb's fonts (DejaVu Sans), which are wider than
  macOS and Windows fonts.

### Troubleshooting

- **Typed text arrives as plain Latin:** IBus is still on the US layout. The input-source
  switch (Super+Space) works only while a Gooey text field has focus; `ibus engine` prints
  the active engine.
- **`ibus list-engine` lacks anthy:** rerun `gnome-session start`; it rebuilds IBus's engine
  cache.
- **No screenshot, or input does nothing:** check `amp orb service logs gnome-shell` and
  `amp orb service status gnome-pipewire`. Absolute pointer motion needs PipeWire.
