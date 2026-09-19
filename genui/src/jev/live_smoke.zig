//! Explicit opt-in direct TypeSafe smoke check. This performs one request and
//! must only be run when `TYPESAFE_API_KEY` is present.

const std = @import("std");
const client_module = @import("client.zig");
const codec = @import("codec.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const api_key = init.environ_map.get("TYPESAFE_API_KEY") orelse return error.MissingTypesafeApiKey;
    if (api_key.len == 0) return error.MissingTypesafeApiKey;

    var transport = client_module.StdHttpTransport{ .io = io, .allocator = allocator };
    const client = client_module.Client{ .transport = transport.transport() };
    const question = codec.Question{
        .id = "smoke",
        .instructions = "Choose exactly one option.",
        .option_ids = &.{"ok"},
        .option_descriptions = &.{"The only valid option"},
    };
    var request_buffer: [codec.request_bytes_max]u8 = undefined;
    var response_buffer: [codec.response_bytes_max]u8 = undefined;
    var parse_scratch: [codec.parse_scratch_bytes_max]u8 = undefined;
    var diagnostics = client_module.FailureDiagnostics{};
    const model = "jev-1.13.0";
    const response = try client.evaluate(api_key, &.{
        .model = model,
        .state_request = "Verify direct API compatibility.",
        .state_context = "Minimal production transport smoke check.",
        .questions = &.{question},
    }, &request_buffer, &response_buffer, &parse_scratch, &diagnostics);
    std.debug.print("status=200 classification=success model={s} answers={d} type=choice probabilities={d}\n", .{
        model,
        response.answer_count,
        response.answers[0].probability_count,
    });
}
