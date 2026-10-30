//! The scripted traces behind the counter and todo goldens.
//!
//! Coordinates are logical pixels read off the 0.3.1 frames' hit records (the
//! centre of each control), so a click lands on the same control in the
//! 0.3.1 runtime and in the core port as long as their layouts agree.

const trace = @import("trace.zig");

pub const counter = trace.Trace{
    .name = "counter",
    .width = 500,
    .height = 350,
    .scale_factor = 2,
    .steps = &.{
        .{ .label = "click +", .step = .{ .click = .{ .x = 155, .y = 245 } } },
        .{ .label = "click + again", .step = .{ .click = .{ .x = 155, .y = 245 } } },
        .{ .label = "click -", .step = .{ .click = .{ .x = 70, .y = 245 } } },
        .{ .label = "click step 5", .step = .{ .click = .{ .x = 130, .y = 304 } } },
        .{ .label = "click + with step 5", .step = .{ .click = .{ .x = 155, .y = 245 } } },
        .{ .label = "hover Reset", .step = .{ .move = .{ .x = 260, .y = 245 } } },
        // The reset message adds a line, so the controls move up 26 px until
        // `setStep` clears the message again.
        .{ .label = "click Reset", .step = .{ .click = .{ .x = 260, .y = 245 } } },
        .{ .label = "click step 10", .step = .{ .click = .{ .x = 174, .y = 272 } } },
        .{ .label = "click - into negative", .step = .{ .click = .{ .x = 70, .y = 245 } } },
        .{ .label = "click Reset & Blur", .step = .{ .click = .{ .x = 384, .y = 245 } } },
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
        // AppKit's `unmarkText` do. Committing straight over a preedit trips
        // a 0.3.1 assertion (`preedit_cursor` outlives the cleared preedit in
        // `TextInputState.insertText`), so the shared trace avoids it.
        .{ .label = "end the composition", .step = .{ .compose = "" } },
        .{ .label = "commit \"caf\u{e9}\"", .step = .{ .text = "caf\u{e9}" } },
        .{ .label = "click Add again", .step = .{ .click = .{ .x = 429, .y = 93 } } },
        .{ .label = "check the first row", .step = .{ .click = .{ .x = 43, .y = 198 } } },
        .{ .label = "filter Active", .step = .{ .click = .{ .x = 104, .y = 143 } } },
        .{ .label = "filter Done", .step = .{ .click = .{ .x = 172, .y = 143 } } },
        .{ .label = "filter All", .step = .{ .click = .{ .x = 44, .y = 143 } } },
        .{ .label = "hover the second Delete", .step = .{ .move = .{ .x = 155, .y = 255 } } },
        .{ .label = "delete the second row", .step = .{ .click = .{ .x = 155, .y = 255 } } },
        .{ .label = "clear completed", .step = .{ .click = .{ .x = 146, .y = 521 } } },
    },
};
