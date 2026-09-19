const std = @import("std");
const core = @import("../core.zig");
const client_module = @import("client.zig");
const codec = @import("codec.zig");

const number_bytes_max = 2;
const question_id_bytes_max = 16;
const candidate_summary_bytes_max = 320;
const parent_description_bytes_max = 128;
const root_instruction_bytes_max = 12 * 1024;
const layout_context_bytes_max = 12 * 1024;
const purpose_bytes_max = 96;

pub const Evaluator = struct {
    client: client_module.Client,
    api_key: []const u8,
    model: []const u8,
    state_request: []const u8,
    state_context: []const u8,
    request_buffer: []u8,
    response_buffer: []u8,
    parse_scratch: []u8,
    diagnostics: *client_module.FailureDiagnostics,

    pub fn coreEvaluator(self: *Evaluator) core.Evaluator {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(self.model.len > 0);
        return .{ .context = self, .evaluate_fn = evaluate };
    }

    fn evaluate(pointer: *anyopaque, request: *const core.EvaluationRequest, response: *core.EvaluationResponse) !void {
        const self: *Evaluator = @ptrCast(@alignCast(pointer));
        std.debug.assert(self.api_key.len > 0);
        std.debug.assert(self.model.len > 0);
        switch (request.*) {
            .selection => |candidates| response.* = .{ .selection = try self.evaluateSelection(candidates) },
            .layout => |layout| response.* = .{ .layout = try self.evaluateLayout(layout.candidates, layout.selection) },
        }
    }

    fn evaluateSelection(self: *Evaluator, candidates: *const core.CandidateSet) !core.Selection {
        std.debug.assert(candidates.count > 0);
        std.debug.assert(candidates.count <= core.candidates_max);
        var question_ids: [core.candidates_max][question_id_bytes_max]u8 = undefined;
        var instruction_storage: [core.candidates_max][candidate_summary_bytes_max]u8 = undefined;
        var root_instruction_storage: [root_instruction_bytes_max]u8 = undefined;
        var option_storage: [core.candidates_max][number_bytes_max]u8 = undefined;
        var option_ids: [core.candidates_max][]const u8 = undefined;
        var option_descriptions: [core.candidates_max][]const u8 = undefined;
        var description_storage: [core.candidates_max][candidate_summary_bytes_max]u8 = undefined;
        var root_candidates: [core.candidates_max]u8 = undefined;
        const root_count = try buildRootOptions(candidates, &option_storage, &option_ids, &option_descriptions, &description_storage, &root_candidates);
        const root_instruction = try buildRootInstruction(candidates, root_candidates[0..root_count], &root_instruction_storage);
        var questions: [core.candidates_max + 1]codec.Question = undefined;
        questions[0] = .{ .id = "root", .instructions = root_instruction, .option_ids = option_ids[0..root_count], .option_descriptions = option_descriptions[0..root_count] };
        for (0..candidates.count) |index| {
            const id = try std.fmt.bufPrint(&question_ids[index], "select_{d}", .{index});
            const instruction = try buildCandidateInstruction("Decide whether to include", index, &candidates.items[index], &instruction_storage[index]);
            questions[index + 1] = includeQuestion(id, instruction);
        }
        const result = try self.call(questions[0 .. candidates.count + 1], self.state_context);
        const selection = try selectionFromAnswers(candidates.count, root_candidates[0..root_count], &result);
        _ = try validateSelection(candidates, &selection);
        return selection;
    }

    fn evaluateLayout(self: *Evaluator, candidates: *const core.CandidateSet, selection: *const core.Selection) !core.Layout {
        std.debug.assert(candidates.count > 0);
        std.debug.assert(candidates.count <= core.candidates_max);
        const selected_count = try validateSelection(candidates, selection);
        if (selected_count == 1) return core.Layout{};
        var selected: [core.candidates_max]u8 = undefined;
        _ = collectSelected(candidates, selection, &selected);
        var parents: [core.candidates_max]u8 = undefined;
        const parent_count = collectSelectedContainers(candidates, selection, &parents);
        std.debug.assert(parent_count > 0);
        var number_storage: [core.candidates_max][number_bytes_max]u8 = undefined;
        var number_ids: [core.candidates_max][]const u8 = undefined;
        buildNumberIds(&number_storage, &number_ids);
        var parent_ids: [core.candidates_max][]const u8 = undefined;
        var parent_descriptions: [core.candidates_max][]const u8 = undefined;
        var description_storage: [core.candidates_max][parent_description_bytes_max]u8 = undefined;
        for (parents[0..parent_count], 0..) |candidate_index, index| {
            parent_ids[index] = number_ids[candidate_index];
            parent_descriptions[index] = try parentDescription(candidate_index, &candidates.items[candidate_index], &description_storage[index]);
        }
        var context_storage: [layout_context_bytes_max]u8 = undefined;
        const layout_context = try buildLayoutContext(self.state_context, candidates, selected[0..selected_count], &context_storage);
        return self.callLayout(candidates, selection, selected[0..selected_count], parents[0..parent_count], parent_ids[0..parent_count], parent_descriptions[0..parent_count], number_ids[0 .. selected_count - 1], layout_context);
    }

    fn callLayout(self: *Evaluator, candidates: *const core.CandidateSet, selection: *const core.Selection, selected: []const u8, parents: []const u8, parent_ids: []const []const u8, parent_descriptions: []const []const u8, order_ids: []const []const u8, layout_context: []const u8) !core.Layout {
        std.debug.assert(selected.len > 1);
        std.debug.assert(parents.len > 0);
        var question_ids: [codec.questions_max][question_id_bytes_max]u8 = undefined;
        var instruction_storage: [codec.questions_max][candidate_summary_bytes_max]u8 = undefined;
        var questions: [codec.questions_max]codec.Question = undefined;
        var question_count: u8 = 0;
        for (selected) |candidate_index| {
            if (candidate_index == selection.root_candidate) continue;
            const parent_id = try std.fmt.bufPrint(&question_ids[question_count], "parent_{d}", .{candidate_index});
            const parent_instruction = try buildCandidateInstruction("Choose the preferred parent for", candidate_index, &candidates.items[candidate_index], &instruction_storage[question_count]);
            questions[question_count] = .{ .id = parent_id, .instructions = parent_instruction, .option_ids = parent_ids, .option_descriptions = parent_descriptions };
            question_count += 1;
            const order_id = try std.fmt.bufPrint(&question_ids[question_count], "order_{d}", .{candidate_index});
            const order_instruction = try buildCandidateInstruction("Choose the preferred sibling rank for", candidate_index, &candidates.items[candidate_index], &instruction_storage[question_count]);
            questions[question_count] = .{ .id = order_id, .instructions = order_instruction, .option_ids = order_ids, .option_descriptions = order_ids };
            question_count += 1;
        }
        const result = try self.call(questions[0..question_count], layout_context);
        return layoutFromPreferences(candidates, selection, selected, parents, &result);
    }

    fn call(self: *Evaluator, questions: []const codec.Question, state_context: []const u8) !codec.Response {
        std.debug.assert(questions.len > 0);
        std.debug.assert(questions.len <= codec.questions_max);
        return self.client.evaluate(self.api_key, &.{
            .model = self.model,
            .state_request = self.state_request,
            .state_context = state_context,
            .questions = questions,
        }, self.request_buffer, self.response_buffer, self.parse_scratch, self.diagnostics);
    }
};

fn buildRootOptions(candidates: *const core.CandidateSet, storage: *[core.candidates_max][number_bytes_max]u8, ids: *[core.candidates_max][]const u8, descriptions: *[core.candidates_max][]const u8, description_storage: *[core.candidates_max][candidate_summary_bytes_max]u8, indexes: *[core.candidates_max]u8) !u8 {
    std.debug.assert(candidates.count > 0);
    std.debug.assert(candidates.count <= core.candidates_max);
    var count: u8 = 0;
    for (candidates.items[0..candidates.count], 0..) |candidate, candidate_index| {
        if (!candidate.can_be_root) continue;
        indexes[count] = @intCast(candidate_index);
        ids[count] = try std.fmt.bufPrint(&storage[count], "{d}", .{candidate_index});
        descriptions[count] = try candidateSummary(candidate_index, &candidate, &description_storage[count]);
        count += 1;
    }
    if (count == 0) return error.NoRootCandidates;
    return count;
}

fn buildRootInstruction(candidates: *const core.CandidateSet, roots: []const u8, output: []u8) ![]const u8 {
    std.debug.assert(roots.len > 0);
    std.debug.assert(roots.len <= core.candidates_max);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("Choose exactly one suitable root. Candidate identities: ");
    for (roots, 0..) |candidate_index, index| {
        var summary_storage: [candidate_summary_bytes_max]u8 = undefined;
        const summary = try candidateSummary(candidate_index, &candidates.items[candidate_index], &summary_storage);
        if (index > 0) try writer.writeAll(" | ");
        try writer.writeAll(summary);
    }
    return writer.buffered();
}

fn includeQuestion(id: []const u8, instruction: []const u8) codec.Question {
    std.debug.assert(id.len > 0);
    std.debug.assert(instruction.len > 0);
    return .{ .id = id, .instructions = instruction, .option_ids = &.{ "no", "yes" }, .option_descriptions = &.{ "Exclude the described candidate", "Include the described candidate" } };
}

fn buildCandidateInstruction(prefix: []const u8, candidate_index: usize, candidate: *const core.Candidate, output: []u8) ![]const u8 {
    std.debug.assert(prefix.len > 0);
    std.debug.assert(candidate_index < core.candidates_max);
    var summary_storage: [candidate_summary_bytes_max]u8 = undefined;
    const summary = try candidateSummary(candidate_index, candidate, &summary_storage);
    return std.fmt.bufPrint(output, "{s}: {s}", .{ prefix, summary });
}

fn candidateSummary(candidate_index: usize, candidate: *const core.Candidate, output: []u8) ![]const u8 {
    std.debug.assert(candidate_index < core.candidates_max);
    std.debug.assert(candidate.key.len > 0);
    const purpose = candidatePurpose(candidate.props);
    const state_binding = candidateStateBinding(candidate.props);
    return std.fmt.bufPrint(output, "index={d}; key={s}; component={s}; purpose={s}; state_binding={s}", .{
        candidate_index,
        candidate.key,
        @tagName(std.meta.activeTag(candidate.props)),
        purpose[0..@min(purpose.len, purpose_bytes_max)],
        state_binding,
    });
}

fn candidatePurpose(props: core.Props) []const u8 {
    std.debug.assert(@sizeOf(core.Props) > 0);
    std.debug.assert(purpose_bytes_max > core.key_bytes_max);
    return switch (props) {
        .stack => "vertical container",
        .row => "horizontal container",
        .card => "grouped card container",
        .text => |value| value.content,
        .button => |value| value.label,
        .input => |value| value.placeholder,
        .checkbox => |value| value.label,
    };
}

fn candidateStateBinding(props: core.Props) []const u8 {
    std.debug.assert(@sizeOf(core.Props) > 0);
    std.debug.assert(core.key_bytes_max < candidate_summary_bytes_max);
    return switch (props) {
        .input => |value| value.state_id,
        .checkbox => |value| value.state_id,
        else => "none",
    };
}

fn parentDescription(candidate_index: usize, candidate: *const core.Candidate, output: []u8) ![]const u8 {
    std.debug.assert(candidate_index < core.candidates_max);
    std.debug.assert(core.key_bytes_max < parent_description_bytes_max);
    return std.fmt.bufPrint(output, "index={d}; key={s}; component={s}", .{
        candidate_index,
        candidate.key,
        @tagName(std.meta.activeTag(candidate.props)),
    });
}

fn buildLayoutContext(base: []const u8, candidates: *const core.CandidateSet, selected: []const u8, output: []u8) ![]const u8 {
    std.debug.assert(selected.len > 1);
    std.debug.assert(selected.len <= core.nodes_max);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("Host context: ");
    try writer.writeAll(base[0..@min(base.len, 1024)]);
    try writer.writeAll(". Selected candidate identities and bindings: ");
    for (selected, 0..) |candidate_index, index| {
        var summary_storage: [candidate_summary_bytes_max]u8 = undefined;
        const summary = try candidateSummary(candidate_index, &candidates.items[candidate_index], &summary_storage);
        if (index > 0) try writer.writeAll(" | ");
        try writer.writeAll(summary);
    }
    try writer.writeAll(". Parent and rank answers are preferences; the host enforces a rooted bounded tree.");
    return writer.buffered();
}

fn selectionFromAnswers(candidate_count: u8, roots: []const u8, response: *const codec.Response) !core.Selection {
    std.debug.assert(candidate_count > 0);
    std.debug.assert(response.answer_count == candidate_count + 1);
    const root_answer = response.answers[0];
    if (root_answer.selected_index >= roots.len) return error.InvalidOptionIndex;
    var selection = core.Selection{ .root_candidate = roots[root_answer.selected_index] };
    for (0..candidate_count) |candidate_index| {
        const answer = response.answers[candidate_index + 1];
        if (answer.selected_index > 1) return error.InvalidOptionIndex;
        selection.selected[candidate_index] = answer.selected_index == 1;
    }
    selection.selected[selection.root_candidate] = true;
    return selection;
}

fn validateSelection(candidates: *const core.CandidateSet, selection: *const core.Selection) !u8 {
    std.debug.assert(candidates.count > 0);
    std.debug.assert(candidates.count <= core.candidates_max);
    if (selection.root_candidate >= candidates.count) return error.InvalidRoot;
    if (!selection.selected[selection.root_candidate]) return error.InvalidRoot;
    if (!candidates.items[selection.root_candidate].can_be_root) return error.InvalidRoot;
    var selected_count: u8 = 0;
    for (selection.selected[0..candidates.count]) |selected| if (selected) {
        if (selected_count >= core.nodes_max) return error.NodeCapacityExceeded;
        selected_count += 1;
    };
    if (selected_count == 0) return error.InvalidRoot;
    if (selected_count > 1 and !core.canContainChildren(candidates.items[selection.root_candidate].props)) return error.RootCannotContainChildren;
    return selected_count;
}

fn collectSelected(candidates: *const core.CandidateSet, selection: *const core.Selection, output: *[core.candidates_max]u8) u8 {
    std.debug.assert(candidates.count > 0);
    std.debug.assert(selection.root_candidate < candidates.count);
    var count: u8 = 0;
    for (0..candidates.count) |candidate_index| {
        if (!selection.selected[candidate_index]) continue;
        output[count] = @intCast(candidate_index);
        count += 1;
    }
    return count;
}

fn collectSelectedContainers(candidates: *const core.CandidateSet, selection: *const core.Selection, output: *[core.candidates_max]u8) u8 {
    std.debug.assert(candidates.count > 0);
    std.debug.assert(candidates.count <= core.candidates_max);
    var count: u8 = 0;
    for (candidates.items[0..candidates.count], 0..) |candidate, candidate_index| {
        if (!selection.selected[candidate_index]) continue;
        if (!core.canContainChildren(candidate.props)) continue;
        output[count] = @intCast(candidate_index);
        count += 1;
    }
    return count;
}

fn buildNumberIds(storage: *[core.candidates_max][number_bytes_max]u8, ids: *[core.candidates_max][]const u8) void {
    std.debug.assert(core.candidates_max <= 100);
    std.debug.assert(number_bytes_max == 2);
    for (0..core.candidates_max) |index| ids[index] = std.fmt.bufPrint(&storage[index], "{d}", .{index}) catch unreachable;
}

fn layoutFromPreferences(candidates: *const core.CandidateSet, selection: *const core.Selection, selected: []const u8, parents: []const u8, response: *const codec.Response) !core.Layout {
    std.debug.assert(selected.len > 1);
    std.debug.assert(response.answer_count == (selected.len - 1) * 2);
    var preferred_parent = [_]u8{0} ** core.candidates_max;
    var preferred_rank = [_]u8{0} ** core.candidates_max;
    readPreferences(selection, selected, parents, response, &preferred_parent, &preferred_rank);
    var layout = core.Layout{};
    var attached = [_]bool{false} ** core.candidates_max;
    var depth = [_]u8{0} ** core.candidates_max;
    attached[selection.root_candidate] = true;
    depth[selection.root_candidate] = 1;
    for (selected) |candidate_index| {
        if (candidate_index == selection.root_candidate) continue;
        const preference = preferred_parent[candidate_index];
        const parent = if (eligibleParent(candidates, selection, candidate_index, preference, &attached, &depth)) preference else selection.root_candidate;
        layout.parent_candidate[candidate_index] = parent;
        depth[candidate_index] = depth[parent] + 1;
        attached[candidate_index] = true;
    }
    deriveSiblingOrder(selection, selected, &preferred_rank, &layout);
    return layout;
}

fn readPreferences(selection: *const core.Selection, selected: []const u8, parents: []const u8, response: *const codec.Response, preferred_parent: *[core.candidates_max]u8, preferred_rank: *[core.candidates_max]u8) void {
    std.debug.assert(selected.len > 1);
    std.debug.assert(parents.len > 0);
    var answer_index: u8 = 0;
    for (selected) |candidate_index| {
        if (candidate_index == selection.root_candidate) continue;
        const parent_index = response.answers[answer_index].selected_index;
        std.debug.assert(parent_index < parents.len);
        preferred_parent[candidate_index] = parents[parent_index];
        answer_index += 1;
        preferred_rank[candidate_index] = response.answers[answer_index].selected_index;
        answer_index += 1;
    }
}

fn eligibleParent(candidates: *const core.CandidateSet, selection: *const core.Selection, child: u8, parent: u8, attached: *const [core.candidates_max]bool, depth: *const [core.candidates_max]u8) bool {
    std.debug.assert(child < candidates.count);
    std.debug.assert(parent < candidates.count);
    if (parent == child) return false;
    if (!selection.selected[parent]) return false;
    if (!core.canContainChildren(candidates.items[parent].props)) return false;
    if (!attached[parent]) return false;
    return depth[parent] < core.depth_max;
}

fn deriveSiblingOrder(selection: *const core.Selection, selected: []const u8, preferred_rank: *const [core.candidates_max]u8, layout: *core.Layout) void {
    std.debug.assert(selected.len > 1);
    std.debug.assert(selection.root_candidate < core.candidates_max);
    for (selected) |parent| {
        var children: [core.nodes_max]u8 = undefined;
        var child_count: u8 = 0;
        for (selected) |candidate_index| {
            if (layout.parent_candidate[candidate_index] != parent) continue;
            children[child_count] = candidate_index;
            child_count += 1;
        }
        sortChildren(children[0..child_count], preferred_rank);
        for (children[0..child_count], 0..) |candidate_index, order| layout.order[candidate_index] = @intCast(order);
    }
}

fn sortChildren(children: []u8, preferred_rank: *const [core.candidates_max]u8) void {
    std.debug.assert(children.len <= core.nodes_max);
    std.debug.assert(preferred_rank.len == core.candidates_max);
    var unsorted: usize = 1;
    while (unsorted < children.len) : (unsorted += 1) {
        const moving = children[unsorted];
        var sorted = unsorted;
        while (sorted > 0) {
            const previous = children[sorted - 1];
            if (preferred_rank[previous] < preferred_rank[moving]) break;
            if (preferred_rank[previous] == preferred_rank[moving] and previous < moving) break;
            children[sorted] = previous;
            sorted -= 1;
        }
        children[sorted] = moving;
    }
}

test "selection instructions expose bounded candidate semantics" {
    var buffer: [candidate_summary_bytes_max]u8 = undefined;
    const candidate = core.Candidate{ .key = "email", .props = .{ .input = .{ .placeholder = "Work email", .state_id = "profile.email" } } };
    const instruction = try buildCandidateInstruction("Decide whether to include", 7, &candidate, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, instruction, "index=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, instruction, "component=input") != null);
    try std.testing.expect(std.mem.indexOf(u8, instruction, "Work email") != null);
    try std.testing.expect(std.mem.indexOf(u8, instruction, "profile.email") != null);
}

test "host repairs self and later parents and duplicate ranks deterministically" {
    var catalog = core.Catalog{};
    const action = try catalog.addAction("save");
    var candidates = core.CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = "root", .props = .{ .card = .{} }, .can_be_root = true });
    _ = try candidates.add(&catalog, .{ .key = "section", .props = .{ .stack = .{} } });
    _ = try candidates.add(&catalog, .{ .key = "title", .props = .{ .text = .{ .content = "Profile" } } });
    _ = try candidates.add(&catalog, .{ .key = "save", .props = .{ .button = .{ .label = "Save", .action = action } } });
    _ = try candidates.add(&catalog, .{ .key = "later", .props = .{ .row = .{} } });
    var selection = core.Selection{ .root_candidate = 0 };
    for (0..5) |index| selection.selected[index] = true;
    const parents = [_]u8{ 0, 1, 4 };
    var response = codec.Response{ .answer_count = 8 };
    response.answers[0].selected_index = 1;
    response.answers[1].selected_index = 0;
    response.answers[2].selected_index = 1;
    response.answers[3].selected_index = 0;
    response.answers[4].selected_index = 2;
    response.answers[5].selected_index = 0;
    response.answers[6].selected_index = 0;
    response.answers[7].selected_index = 0;
    const layout = try layoutFromPreferences(&candidates, &selection, &.{ 0, 1, 2, 3, 4 }, &parents, &response);
    try std.testing.expectEqual(@as(?u8, 0), layout.parent_candidate[1]);
    try std.testing.expectEqual(@as(?u8, 1), layout.parent_candidate[2]);
    try std.testing.expectEqual(@as(?u8, 0), layout.parent_candidate[3]);
    try std.testing.expect(layout.order[1] != layout.order[3]);
}

test "adversarial Jev preferences compose a valid deterministic tree" {
    var catalog = core.Catalog{};
    const action = try catalog.addAction("save");
    var candidates = core.CandidateSet{};
    try addAdversarialCandidates(&catalog, action, &candidates);
    const Fixture = struct {
        calls: u8 = 0,
        fn post(pointer: *anyopaque, request: *const client_module.HttpRequest, response_buffer: []u8, diagnostics: *client_module.FailureDiagnostics) !client_module.HttpResponse {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            _ = diagnostics;
            const selection = self.calls == 0;
            const body = if (selection) try writeSelectionResponse(response_buffer, 5) else try writeAdversarialLayoutResponse(response_buffer);
            if (selection) try std.testing.expect(std.mem.indexOf(u8, request.body, "component=button") != null);
            if (!selection) try std.testing.expect(std.mem.indexOf(u8, request.body, "Selected candidate identities") != null);
            self.calls += 1;
            return .{ .status = 200, .body = body };
        }
    };
    var fixture = Fixture{};
    var buffers = TestBuffers{};
    var diagnostics = client_module.FailureDiagnostics{};
    var evaluator = testEvaluator(&fixture, Fixture.post, &buffers, &diagnostics);
    var spec = core.Spec{};
    try core.compose(evaluator.coreEvaluator(), &candidates, 11, &spec);
    try std.testing.expectEqual(@as(u8, 2), fixture.calls);
    try core.validateSpec(&candidates, &spec);
    try std.testing.expectEqual(@as(u8, 5), spec.node_count);
}

test "excessive Jev selection fails before the layout request" {
    const Fixture = struct {
        calls: u8 = 0,
        fn post(pointer: *anyopaque, request: *const client_module.HttpRequest, response_buffer: []u8, diagnostics: *client_module.FailureDiagnostics) !client_module.HttpResponse {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            _ = request;
            _ = diagnostics;
            if (self.calls != 0) return error.UnexpectedLayoutRequest;
            self.calls += 1;
            return .{ .status = 200, .body = try writeSelectionResponse(response_buffer, core.nodes_max + 1) };
        }
    };
    const catalog = core.Catalog{};
    var candidates = core.CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = "root", .props = .{ .card = .{} }, .can_be_root = true });
    var keys: [core.nodes_max][4]u8 = undefined;
    for (0..core.nodes_max) |index| {
        const key = try std.fmt.bufPrint(&keys[index], "c{d}", .{index});
        _ = try candidates.add(&catalog, .{ .key = key, .props = .{ .text = .{ .content = "item" } } });
    }
    var fixture = Fixture{};
    var buffers = TestBuffers{};
    var diagnostics = client_module.FailureDiagnostics{};
    var evaluator = testEvaluator(&fixture, Fixture.post, &buffers, &diagnostics);
    var spec = core.Spec{};
    try std.testing.expectError(error.NodeCapacityExceeded, core.compose(evaluator.coreEvaluator(), &candidates, 1, &spec));
    try std.testing.expectEqual(@as(u8, 1), fixture.calls);
}

const TestBuffers = struct {
    request: [codec.request_bytes_max]u8 = undefined,
    response: [codec.response_bytes_max]u8 = undefined,
    scratch: [codec.parse_scratch_bytes_max]u8 = undefined,
};

fn testEvaluator(context: *anyopaque, post_fn: *const fn (*anyopaque, *const client_module.HttpRequest, []u8, *client_module.FailureDiagnostics) anyerror!client_module.HttpResponse, buffers: *TestBuffers, diagnostics: *client_module.FailureDiagnostics) Evaluator {
    std.debug.assert(@intFromPtr(context) != 0);
    std.debug.assert(@intFromPtr(diagnostics) != 0);
    return .{
        .client = .{ .transport = .{ .context = context, .post_fn = post_fn } },
        .api_key = "test-key",
        .model = "jev-1.13.0",
        .state_request = "Build profile controls",
        .state_context = "Editing profile",
        .request_buffer = &buffers.request,
        .response_buffer = &buffers.response,
        .parse_scratch = &buffers.scratch,
        .diagnostics = diagnostics,
    };
}

fn addAdversarialCandidates(catalog: *const core.Catalog, action: u8, candidates: *core.CandidateSet) !void {
    std.debug.assert(catalog.permits(action));
    std.debug.assert(candidates.count == 0);
    _ = try candidates.add(catalog, .{ .key = "root", .props = .{ .card = .{} }, .can_be_root = true });
    _ = try candidates.add(catalog, .{ .key = "section", .props = .{ .stack = .{} } });
    _ = try candidates.add(catalog, .{ .key = "title", .props = .{ .text = .{ .content = "Profile" } } });
    _ = try candidates.add(catalog, .{ .key = "save", .props = .{ .button = .{ .label = "Save", .action = action } } });
    _ = try candidates.add(catalog, .{ .key = "later", .props = .{ .row = .{} } });
}

fn writeSelectionResponse(output: []u8, candidate_count: u8) ![]const u8 {
    std.debug.assert(candidate_count > 0);
    std.debug.assert(candidate_count <= core.candidates_max);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"answers\":{");
    try writeChoiceAnswer(&writer, "root", "0", &.{"0"});
    for (0..candidate_count) |index| {
        var id_storage: [question_id_bytes_max]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_storage, "select_{d}", .{index});
        try writer.writeByte(',');
        try writeChoiceAnswer(&writer, id, "yes", &.{ "no", "yes" });
    }
    try writer.writeAll("}}");
    return writer.buffered();
}

fn writeAdversarialLayoutResponse(output: []u8) ![]const u8 {
    std.debug.assert(output.len >= 2048);
    std.debug.assert(core.candidates_max >= 5);
    const candidates = [_]u8{ 1, 2, 3, 4 };
    const parents = [_][]const u8{ "0", "1", "4" };
    const preferred_parents = [_][]const u8{ "1", "1", "4", "0" };
    const ranks = [_][]const u8{ "0", "1", "2", "3" };
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"answers\":{");
    for (candidates, 0..) |candidate, index| {
        var parent_id: [question_id_bytes_max]u8 = undefined;
        var order_id: [question_id_bytes_max]u8 = undefined;
        if (index > 0) try writer.writeByte(',');
        try writeChoiceAnswer(&writer, try std.fmt.bufPrint(&parent_id, "parent_{d}", .{candidate}), preferred_parents[index], &parents);
        try writer.writeByte(',');
        try writeChoiceAnswer(&writer, try std.fmt.bufPrint(&order_id, "order_{d}", .{candidate}), "0", &ranks);
    }
    try writer.writeAll("}}");
    return writer.buffered();
}

fn writeChoiceAnswer(writer: *std.Io.Writer, id: []const u8, selected: []const u8, options: []const []const u8) !void {
    std.debug.assert(id.len > 0);
    std.debug.assert(options.len > 0);
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(":{\"type\":\"choice\",\"choice\":");
    try std.json.Stringify.value(selected, .{}, writer);
    try writer.writeAll(",\"probabilities\":{");
    for (options, 0..) |option, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(option, .{}, writer);
        try writer.writeByte(':');
        try writer.writeByte(if (std.mem.eql(u8, option, selected)) '1' else '0');
    }
    try writer.writeAll("},\"confidence\":1}");
}
