const std = @import("std");

pub const request_bytes_max = 64 * 1024;
pub const response_bytes_max = 32 * 1024;
pub const parse_scratch_bytes_max = 256 * 1024;
pub const questions_max = 64;
pub const options_max = 32;
pub const id_bytes_max = 64;

pub const Question = struct {
    id: []const u8,
    instructions: []const u8,
    option_ids: []const []const u8,
    option_descriptions: []const []const u8,
};

pub const Request = struct {
    model: []const u8,
    state_request: []const u8,
    state_context: []const u8,
    questions: []const Question,
};

pub const Choice = struct {
    selected_index: u8 = 0,
    confidence: f64 = 0,
    probabilities: [options_max]f64 = [_]f64{0} ** options_max,
    probability_count: u8 = 0,
};

pub const Response = struct {
    answers: [questions_max]Choice = undefined,
    answer_count: u8 = 0,
};

pub fn encodeRequest(request: *const Request, output: []u8) ![]u8 {
    std.debug.assert(request.questions.len > 0);
    std.debug.assert(request.questions.len <= questions_max);
    try validateRequest(request);
    const bounded_output = output[0..@min(output.len, request_bytes_max)];
    var writer = std.Io.Writer.fixed(bounded_output);
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, &writer);
    try writer.writeAll(",\"state\":{\"request\":");
    try std.json.Stringify.value(request.state_request, .{}, &writer);
    try writer.writeAll(",\"context\":");
    try std.json.Stringify.value(request.state_context, .{}, &writer);
    try writer.writeAll("},\"questions\":{");
    for (request.questions, 0..) |question, question_index| {
        if (question_index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(question.id, .{}, &writer);
        try writer.writeAll(":{\"type\":\"choice\",\"instructions\":");
        try std.json.Stringify.value(question.instructions, .{}, &writer);
        try writer.writeAll(",\"criteria\":{");
        for (question.option_ids, question.option_descriptions, 0..) |id, description, option_index| {
            if (option_index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(id, .{}, &writer);
            try writer.writeByte(':');
            try std.json.Stringify.value(description, .{}, &writer);
        }
        try writer.writeAll("}}");
    }
    try writer.writeAll("}}");
    return writer.buffered();
}

pub fn decodeResponse(bytes: []const u8, questions: []const Question, scratch: []u8) !Response {
    std.debug.assert(questions.len > 0);
    std.debug.assert(questions.len <= questions_max);
    if (bytes.len == 0) return error.MalformedResponse;
    if (bytes.len > response_bytes_max) return error.ResponseTooLarge;
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.ParseScratchTooSmall,
        else => error.MalformedResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const answers_value = parsed.value.object.get("answers") orelse return error.MalformedResponse;
    if (answers_value != .object) return error.MalformedResponse;
    if (answers_value.object.count() != questions.len) return error.AnswerCountMismatch;

    var result = Response{ .answer_count = @intCast(questions.len) };
    for (questions, 0..) |question, question_index| {
        const answer = answers_value.object.get(question.id) orelse return error.MissingAnswer;
        result.answers[question_index] = try decodeChoice(answer, &question);
    }
    return result;
}

fn validateRequest(request: *const Request) !void {
    if (request.model.len == 0) return error.InvalidRequest;
    if (request.questions.len == 0 or request.questions.len > questions_max) return error.TooManyQuestions;
    for (request.questions, 0..) |question, question_index| {
        if (!validId(question.id)) return error.InvalidQuestionId;
        if (question.instructions.len == 0) return error.InvalidRequest;
        if (question.option_ids.len == 0 or question.option_ids.len > options_max) return error.TooManyOptions;
        if (question.option_ids.len != question.option_descriptions.len) return error.InvalidRequest;
        for (request.questions[0..question_index]) |previous| {
            if (std.mem.eql(u8, question.id, previous.id)) return error.DuplicateQuestion;
        }
        for (question.option_ids, 0..) |option_id, option_index| {
            if (!validId(option_id)) return error.InvalidOptionId;
            for (question.option_ids[0..option_index]) |previous| {
                if (std.mem.eql(u8, option_id, previous)) return error.DuplicateOption;
            }
        }
    }
}

fn decodeChoice(value: std.json.Value, question: *const Question) !Choice {
    if (value != .object) return error.MalformedResponse;
    const type_value = value.object.get("type") orelse return error.MalformedResponse;
    const selected_value = value.object.get("choice") orelse return error.MalformedResponse;
    const confidence_value = value.object.get("confidence") orelse return error.MalformedResponse;
    const probabilities_value = value.object.get("probabilities") orelse return error.MalformedResponse;
    if (type_value != .string) return error.InvalidAnswerType;
    if (!std.mem.eql(u8, type_value.string, "choice")) return error.InvalidAnswerType;
    if (selected_value != .string or probabilities_value != .object) return error.MalformedResponse;
    const confidence = jsonFloat(confidence_value) orelse return error.MalformedResponse;
    if (!validProbability(confidence)) return error.InvalidProbability;
    if (probabilities_value.object.count() != question.option_ids.len) return error.ProbabilityCountMismatch;

    var result = Choice{ .confidence = confidence, .probability_count = @intCast(question.option_ids.len) };
    var selected_index: ?u8 = null;
    var probability_sum: f64 = 0;
    for (question.option_ids, 0..) |option_id, option_index| {
        if (std.mem.eql(u8, option_id, selected_value.string)) selected_index = @intCast(option_index);
        const probability_value = probabilities_value.object.get(option_id) orelse return error.MissingProbability;
        const probability = jsonFloat(probability_value) orelse return error.InvalidProbability;
        if (!validProbability(probability)) return error.InvalidProbability;
        result.probabilities[option_index] = probability;
        probability_sum += probability;
    }
    result.selected_index = selected_index orelse return error.InvalidOptionIndex;
    if (@abs(probability_sum - 1.0) > 0.001) return error.InvalidProbabilitySum;
    return result;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > id_bytes_max) return false;
    for (id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') continue;
        return false;
    }
    return true;
}

fn validProbability(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

fn jsonFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => null,
    };
}

test "multi-question request and response preserve answer order" {
    const questions = [_]Question{
        .{ .id = "root", .instructions = "Choose root.", .option_ids = &.{ "0", "1" }, .option_descriptions = &.{ "Stack", "Card" } },
        .{ .id = "select_1", .instructions = "Include candidate?", .option_ids = &.{ "no", "yes" }, .option_descriptions = &.{ "Exclude", "Include" } },
    };
    var encoded: [4096]u8 = undefined;
    const body = try encodeRequest(&.{
        .model = "jev-1.13.0",
        .state_request = "Build settings",
        .state_context = "Account",
        .questions = &questions,
    }, &encoded);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"select_1\"") != null);
    const fixture = "{\"answers\":{\"root\":{\"type\":\"choice\",\"choice\":\"0\",\"probabilities\":{\"0\":0.8,\"1\":0.2},\"confidence\":0.9},\"select_1\":{\"type\":\"choice\",\"choice\":\"yes\",\"probabilities\":{\"no\":0.1,\"yes\":0.9},\"confidence\":0.8}}}";
    var scratch: [16 * 1024]u8 = undefined;
    const response = try decodeResponse(fixture, &questions, &scratch);
    try std.testing.expectEqual(@as(u8, 2), response.answer_count);
    try std.testing.expectEqual(@as(u8, 0), response.answers[0].selected_index);
    try std.testing.expectEqual(@as(u8, 1), response.answers[1].selected_index);
}

test "response rejects duplicate, missing, and extra answers" {
    const question = Question{ .id = "root", .instructions = "Choose.", .option_ids = &.{"0"}, .option_descriptions = &.{"Stack"} };
    var scratch: [16 * 1024]u8 = undefined;
    try std.testing.expectError(error.MalformedResponse, decodeResponse("[]", &.{question}, &scratch));
    const duplicate = "{\"answers\":{\"root\":{\"type\":\"choice\",\"choice\":\"0\",\"probabilities\":{\"0\":1},\"confidence\":1},\"root\":{\"type\":\"choice\",\"choice\":\"0\",\"probabilities\":{\"0\":1},\"confidence\":1}}}";
    try std.testing.expectError(error.MalformedResponse, decodeResponse(duplicate, &.{question}, &scratch));
    try std.testing.expectError(error.AnswerCountMismatch, decodeResponse("{\"answers\":{}}", &.{question}, &scratch));
    const extra = "{\"answers\":{\"root\":{},\"other\":{}}}";
    try std.testing.expectError(error.AnswerCountMismatch, decodeResponse(extra, &.{question}, &scratch));
}

test "response rejects answer type, option, distributions, and size" {
    const question = Question{ .id = "root", .instructions = "Choose.", .option_ids = &.{ "0", "1" }, .option_descriptions = &.{ "Stack", "Card" } };
    var scratch: [16 * 1024]u8 = undefined;
    const wrong_type = "{\"answers\":{\"root\":{\"type\":\"score\",\"choice\":\"0\",\"probabilities\":{\"0\":0.5,\"1\":0.5},\"confidence\":1}}}";
    try std.testing.expectError(error.InvalidAnswerType, decodeResponse(wrong_type, &.{question}, &scratch));
    const invalid_option = "{\"answers\":{\"root\":{\"type\":\"choice\",\"choice\":\"2\",\"probabilities\":{\"0\":0.5,\"1\":0.5},\"confidence\":1}}}";
    try std.testing.expectError(error.InvalidOptionIndex, decodeResponse(invalid_option, &.{question}, &scratch));
    const invalid_sum = "{\"answers\":{\"root\":{\"type\":\"choice\",\"choice\":\"0\",\"probabilities\":{\"0\":0.6,\"1\":0.3},\"confidence\":1}}}";
    try std.testing.expectError(error.InvalidProbabilitySum, decodeResponse(invalid_sum, &.{question}, &scratch));
    var oversized: [response_bytes_max + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(error.ResponseTooLarge, decodeResponse(&oversized, &.{question}, &scratch));
}

test "request rejects malformed and duplicate IDs" {
    var output: [4096]u8 = undefined;
    const bad_question = Question{ .id = "bad id", .instructions = "Choose.", .option_ids = &.{"0"}, .option_descriptions = &.{"Stack"} };
    try std.testing.expectError(error.InvalidQuestionId, encodeRequest(&.{ .model = "jev", .state_request = "x", .state_context = "y", .questions = &.{bad_question} }, &output));
    const bad_option = Question{ .id = "root", .instructions = "Choose.", .option_ids = &.{"bad/id"}, .option_descriptions = &.{"Stack"} };
    try std.testing.expectError(error.InvalidOptionId, encodeRequest(&.{ .model = "jev", .state_request = "x", .state_context = "y", .questions = &.{bad_option} }, &output));
}
