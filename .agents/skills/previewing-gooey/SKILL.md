---
name: previewing-gooey
description: Builds and launches the Gooey showcase in a headless Wayland/Vulkan session and captures a reviewable screenshot. Use when asked to run, preview, inspect, or screenshot the Gooey application in an Amp orb.
compatibility: Requires an Amp Linux orb prepared by .agents/setup.
---

# Previewing Gooey

Run the Gooey showcase under a supervised headless Weston compositor and capture its rendered output.

## Capture workflow

From the repository root, run:

```bash
.agents/skills/previewing-gooey/scripts/capture-showcase
```

The script:

1. Builds only the showcase with the checked-in SPIR-V shaders.
2. Starts Weston and Gooey as supervised orb services.
3. Uses Mesa's software Vulkan renderer when the orb has no GPU.
4. Captures the Weston output into `.amp/in/artifacts/gooey-showcase.png`.
5. Leaves both services running for log and status inspection.

Pass a repository-relative output path as the first argument when a different artifact name is needed.

## Verification

After capture:

- Use `view_media` on the output file and verify the requested UI is visible.
- Inspect `amp orb service status gooey-app` if the screenshot is blank.
- Inspect `amp orb service logs gooey-app` for startup or rendering failures.
- Present the image using its workspace file URI.

## Teardown

Stop the preview services when they are no longer needed:

```bash
amp orb service stop gooey-app
amp orb service stop gooey-wayland
```

Do not launch Weston or Gooey with `&`, `nohup`, or `setsid`; orb services must survive Amp process restarts.
