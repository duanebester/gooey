//! Coordinates are logical pixels at the centre of each control, read off the
//! golden's hit records; a layout change must move them with it.

const trace = @import("trace.zig");

pub const counter = trace.Trace{
    .name = "counter",
    .width = 580,
    .height = 350,
    .scale_factor = 2,
    .steps = &.{
        .{ .label = "click +", .step = .{ .click = .{ .x = 485, .y = 175 } } },
        .{ .label = "click + again", .step = .{ .click = .{ .x = 485, .y = 175 } } },
        .{ .label = "click -", .step = .{ .click = .{ .x = 402, .y = 175 } } },
        .{ .label = "click step 5", .step = .{ .click = .{ .x = 485, .y = 82 } } },
        .{ .label = "click + with step 5", .step = .{ .click = .{ .x = 485, .y = 175 } } },
        .{ .label = "hover Reset", .step = .{ .move = .{ .x = 62, .y = 268 } } },
        .{ .label = "click Reset", .step = .{ .click = .{ .x = 62, .y = 268 } } },
        .{ .label = "click step 10", .step = .{ .click = .{ .x = 528, .y = 82 } } },
        .{ .label = "click - into negative", .step = .{ .click = .{ .x = 402, .y = 175 } } },
        .{ .label = "click Reset & Blur", .step = .{ .click = .{ .x = 151, .y = 268 } } },
    },
};

pub const todo = trace.Trace{
    .name = "todo",
    .width = 480,
    .height = 560,
    .scale_factor = 2,
    .steps = &.{
        .{ .label = "click the draft input", .step = .{ .click = .{ .x = 204, .y = 93 } } },
        .{ .label = "type \"buy milk\"", .step = .{ .text = "buy milk" } },
        .{ .label = "backspace", .step = .{ .key = .delete } },
        .{ .label = "type \"k\"", .step = .{ .text = "k" } },
        .{ .label = "click Add", .step = .{ .click = .{ .x = 429, .y = 93 } } },
        .{ .label = "click the draft input again", .step = .{ .click = .{ .x = 204, .y = 93 } } },
        .{ .label = "compose \"ca\"", .step = .{ .compose = "ca" } },
        .{ .label = "compose \"caf\"", .step = .{ .compose = "caf" } },
        // End the preedit before committing, as Wayland's text-input-v3 and
        // AppKit's `unmarkText` do: committing straight over a preedit trips an
        // assertion (`preedit_cursor` outlives the cleared preedit in
        // `TextInputState.insertText`), so the shared trace avoids it.
        .{ .label = "end the composition", .step = .{ .compose = "" } },
        .{ .label = "commit \"caf\u{e9}\"", .step = .{ .text = "caf\u{e9}" } },
        .{ .label = "click Add again", .step = .{ .click = .{ .x = 429, .y = 93 } } },
        .{ .label = "check the first row", .step = .{ .click = .{ .x = 43, .y = 198 } } },
        .{ .label = "filter Active", .step = .{ .click = .{ .x = 104, .y = 143 } } },
        .{ .label = "filter Done", .step = .{ .click = .{ .x = 172, .y = 143 } } },
        .{ .label = "filter All", .step = .{ .click = .{ .x = 44, .y = 143 } } },
        // The rows fill the list, so Delete sits at its right end.
        .{ .label = "hover the second Delete", .step = .{ .move = .{ .x = 413, .y = 255 } } },
        .{ .label = "delete the second row", .step = .{ .click = .{ .x = 413, .y = 255 } } },
        .{ .label = "clear completed", .step = .{ .click = .{ .x = 146, .y = 521 } } },
    },
};

pub const actions = trace.Trace{
    .name = "actions",
    .width = 800,
    .height = 600,
    .scale_factor = 2,
    .steps = &.{
        .{ .label = "cmd-z, nothing focused", .step = .{ .chord = .{
            .key = .z,
            .modifiers = .{ .cmd = true },
        } } },
        .{ .label = "cmd-shift-z", .step = .{ .chord = .{
            .key = .z,
            .modifiers = .{ .cmd = true, .shift = true },
        } } },
        .{ .label = "escape", .step = .{ .key = .escape } },
        // "Editor" is not on the focus path yet, so its binding does not match.
        .{ .label = "cmd-s outside the editor", .step = .{ .chord = .{
            .key = .s,
            .modifiers = .{ .cmd = true },
        } } },
        .{ .label = "click the editor input", .step = .{ .click = .{ .x = 124, .y = 120 } } },
        .{ .label = "type \"hi\"", .step = .{ .text = "hi" } },
        .{ .label = "cmd-s in the editor", .step = .{ .chord = .{
            .key = .s,
            .modifiers = .{ .cmd = true },
        } } },
        .{ .label = "cmd-z in the editor", .step = .{ .chord = .{
            .key = .z,
            .modifiers = .{ .cmd = true },
        } } },
        .{ .label = "click Undo", .step = .{ .click = .{ .x = 94, .y = 174 } } },
        .{ .label = "click Redo", .step = .{ .click = .{ .x = 262, .y = 174 } } },
    },
};

/// The grid example: a form, a table of row boxes, and a dashboard on one
/// frame, then the pointer over the second table row to show its hover.
pub const grid = trace.Trace{
    .name = "grid",
    .width = 1240,
    .height = 760,
    .scale_factor = 2,
    .steps = &.{
        .{ .label = "hover the Grace Hopper row", .step = .{ .move = .{ .x = 900, .y = 147 } } },
    },
};

/// `text_truncation`: one frame of cut names and clamped cards, then the
/// pointer over the sidebar, which nothing in it answers.
pub const truncation = trace.Trace{
    .name = "truncation",
    .width = 780,
    .height = 600,
    .scale_factor = 2,
    .steps = &.{
        .{ .label = "move over the sidebar", .step = .{ .move = .{ .x = 120, .y = 90 } } },
    },
};
