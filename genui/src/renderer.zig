const std = @import("std");
const gooey = @import("gooey");
const core = @import("core.zig");

pub const control_id_bytes_max = core.key_bytes_max * 2 + 1;

pub const ActionEvent = struct {
    artifact_id: core.Key,
    revision: u32,
    node_index: u8,
    action_tag: u8,
};

pub const ValueEvent = struct {
    artifact_id: core.Key,
    revision: u32,
    node_index: u8,
    state_index: u8,
    value: core.StateValue,
};

const ActionBinding = struct { renderer: *Renderer, event: ActionEvent };
const ValueBinding = struct {
    renderer: *Renderer,
    artifact_id: core.Key,
    state: *core.RuntimeState,
    scratch: ?*InputScratch,
    revision: u32,
    node_index: u8,
    state_index: u8,
};

const InputScratch = struct {
    bytes: [core.state_text_bytes_max]u8 = [_]u8{0} ** core.state_text_bytes_max,
    view: []const u8 = "",
    state_index: u8 = 0,
    initialized: bool = false,

    fn set(self: *InputScratch, state_index: u8, text: []const u8) !void {
        std.debug.assert(text.len <= core.state_text_bytes_max);
        std.debug.assert(state_index < core.state_entries_max);
        if (text.len > self.bytes.len) return error.StateTextTooLong;
        @memset(&self.bytes, 0);
        @memcpy(self.bytes[0..text.len], text);
        self.view = self.bytes[0..text.len];
        self.state_index = state_index;
        self.initialized = true;
    }

    fn ownsView(self: *const InputScratch) bool {
        std.debug.assert(self.view.len <= core.state_text_bytes_max);
        std.debug.assert(self.bytes.len == core.state_text_bytes_max);
        const storage_start = @intFromPtr(&self.bytes);
        const storage_end = storage_start + self.bytes.len;
        const view_start = @intFromPtr(self.view.ptr);
        if (view_start < storage_start or view_start > storage_end) return false;
        return self.view.len <= storage_end - view_start;
    }
};

fn syncInputScratch(scratch: *InputScratch, state_index: u8, state_text: []const u8) !void {
    std.debug.assert(state_index < core.state_entries_max);
    std.debug.assert(state_text.len <= core.state_text_bytes_max);
    if (!scratch.initialized) try scratch.set(state_index, state_text);
    if (scratch.state_index != state_index) return error.ArtifactBindingChanged;
    if (scratch.ownsView() and !std.mem.eql(u8, scratch.view, state_text)) try scratch.set(state_index, state_text);
}

pub const Artifact = struct {
    // IDs, bindings, and input views become callback-visible after attach.
    // `pinned_address` makes moving the artifact after that point an error.
    id: core.Key,
    owner: ?*Renderer = null,
    candidates: ?*const core.CandidateSet = null,
    pinned_address: usize = 0,
    control_ids: [core.candidates_max][control_id_bytes_max]u8 = undefined,
    control_id_lengths: [core.candidates_max]u8 = [_]u8{0} ** core.candidates_max,
    action_bindings: [core.candidates_max]ActionBinding = undefined,
    value_bindings: [core.candidates_max]ValueBinding = undefined,
    input_scratch: [core.candidates_max]InputScratch = [_]InputScratch{.{}} ** core.candidates_max,

    pub fn init(id: []const u8) !Artifact {
        if (id.len == 0) return error.InvalidArtifactId;
        if (std.mem.indexOfScalar(u8, id, '/') != null) return error.InvalidArtifactId;
        return .{ .id = core.Key.init(id) catch return error.InvalidArtifactId };
    }

    pub fn initStatic(comptime id: []const u8) Artifact {
        if (id.len == 0) @compileError("artifact id must not be empty");
        if (id.len > core.key_bytes_max) @compileError("artifact id exceeds key_bytes_max");
        if (std.mem.indexOfScalar(u8, id, '/') != null) @compileError("artifact id must not contain '/'");
        return .{ .id = core.Key.init(id) catch unreachable };
    }

    fn attach(self: *Artifact, renderer: *Renderer, candidates: *const core.CandidateSet) !void {
        std.debug.assert(candidates.count <= core.candidates_max);
        std.debug.assert(self.id.len > 0);
        try renderer.ensureStable();
        const address = @intFromPtr(self);
        if (self.pinned_address == 0) self.pinned_address = address;
        if (self.pinned_address != address) return error.ArtifactMoved;
        if (self.owner) |owner| {
            if (owner != renderer) return error.ArtifactRendererMismatch;
        } else self.owner = renderer;
        if (self.candidates) |existing| {
            if (existing != candidates) return error.ArtifactCandidateMismatch;
        } else self.candidates = candidates;
    }

    fn controlId(self: *Artifact, candidate_index: u8, key: []const u8) ![]const u8 {
        std.debug.assert(candidate_index < core.candidates_max);
        std.debug.assert(key.len <= core.key_bytes_max);
        // The first slash is an unambiguous boundary because artifact IDs
        // forbid it; candidate keys may contain additional slashes safely.
        std.debug.assert(std.mem.indexOfScalar(u8, self.id.slice(), '/') == null);
        const expected_len = self.id.len + 1 + key.len;
        if (self.control_id_lengths[candidate_index] == 0) {
            const output = self.control_ids[candidate_index][0..expected_len];
            @memcpy(output[0..self.id.len], self.id.slice());
            output[self.id.len] = '/';
            @memcpy(output[self.id.len + 1 ..], key);
            self.control_id_lengths[candidate_index] = @intCast(expected_len);
        }
        const existing = self.control_ids[candidate_index][0..self.control_id_lengths[candidate_index]];
        if (existing.len != expected_len) return error.ArtifactCandidateChanged;
        if (!std.mem.eql(u8, existing[self.id.len + 1 ..], key)) return error.ArtifactCandidateChanged;
        return existing;
    }
};

pub const Renderer = struct {
    events: [core.events_max]ActionEvent = undefined,
    event_head: u8 = 0,
    event_count: u8 = 0,
    event_overflowed: bool = false,
    value_events: [core.events_max]ValueEvent = undefined,
    value_event_head: u8 = 0,
    value_event_count: u8 = 0,
    value_event_overflowed: bool = false,
    binding_failed: bool = false,
    pinned_address: usize = 0,

    const Frame = struct { node_index: u8, exit: bool, depth: u8 };

    fn ensureStable(self: *Renderer) !void {
        const address = @intFromPtr(self);
        if (self.pinned_address == 0) self.pinned_address = address;
        if (self.pinned_address != address) return error.RendererMoved;
    }

    pub fn renderArtifact(self: *Renderer, cx: *gooey.Cx, artifact: *Artifact, catalog: *const core.Catalog, candidates: *const core.CandidateSet, spec: *const core.Spec) !void {
        // Traversal and binding use only fixed inline storage. Gooey's retained
        // widget initialization/input buffers have their own allocation policy.
        try self.renderInternal(cx, artifact, catalog, null, candidates, spec);
    }

    pub fn renderArtifactWithState(self: *Renderer, cx: *gooey.Cx, artifact: *Artifact, catalog: *const core.Catalog, state: *core.RuntimeState, candidates: *const core.CandidateSet, spec: *const core.Spec) !void {
        try self.renderInternal(cx, artifact, catalog, state, candidates, spec);
    }

    fn renderInternal(self: *Renderer, cx: *gooey.Cx, artifact: *Artifact, catalog: *const core.Catalog, state: ?*core.RuntimeState, candidates: *const core.CandidateSet, spec: *const core.Spec) !void {
        std.debug.assert(spec.node_count <= core.nodes_max);
        std.debug.assert(candidates.count <= core.candidates_max);
        try artifact.attach(self, candidates);
        try core.validateSpec(candidates, spec);
        try core.validateCatalogBindings(catalog, state, candidates);
        const root = spec.root_index orelse return error.MissingRoot;
        var stack: [core.nodes_max * 2]Frame = undefined;
        var stack_count: u8 = 1;
        var boxes_open: u8 = 0;
        errdefer closeBoxes(cx, &boxes_open);
        stack[0] = .{ .node_index = root, .exit = false, .depth = 1 };
        while (stack_count > 0) {
            stack_count -= 1;
            const frame = stack[stack_count];
            if (frame.exit) {
                cx.dynamic.endBox();
                boxes_open -= 1;
                continue;
            }
            const node = spec.nodes[frame.node_index];
            const candidate = candidates.items[node.candidate_index];
            const id = try artifact.controlId(node.candidate_index, candidate.key);
            if (core.canContainChildren(candidate.props)) {
                try beginContainer(cx, id, candidate.props);
                boxes_open += 1;
                try pushContainerFrames(spec, frame, &stack, &stack_count);
            } else try self.renderControl(cx, artifact, catalog, state, spec.revision, frame.node_index, node.candidate_index, id, candidate.props);
        }
    }

    fn renderControl(self: *Renderer, cx: *gooey.Cx, artifact: *Artifact, catalog: *const core.Catalog, state_optional: ?*core.RuntimeState, revision: u32, node_index: u8, candidate_index: u8, id: []const u8, props: core.Props) !void {
        std.debug.assert(node_index < core.nodes_max);
        std.debug.assert(candidate_index < core.candidates_max);
        switch (props) {
            .text => |value| cx.render(gooey.ui.text(value.content, .{})),
            .button => |value| try self.renderButton(cx, artifact, catalog, revision, node_index, candidate_index, id, value),
            .input => |value| try self.renderInput(cx, artifact, state_optional.?, revision, node_index, candidate_index, id, value),
            .checkbox => |value| try self.renderCheckbox(cx, artifact, state_optional.?, revision, node_index, candidate_index, id, value),
            .stack, .row, .card => unreachable,
        }
    }

    fn renderButton(self: *Renderer, cx: *gooey.Cx, artifact: *Artifact, catalog: *const core.Catalog, revision: u32, node_index: u8, candidate_index: u8, id: []const u8, props: core.ButtonProps) !void {
        const action = props.action orelse return error.ButtonMissingAction;
        if (!catalog.permits(action)) return error.UnknownAction;
        bindAction(self, artifact, revision, node_index, candidate_index, action);
        cx.render(gooey.components.Button{
            .id = id,
            .label = props.label,
            .on_click_handler = actionHandler(&artifact.action_bindings[candidate_index]),
        });
    }

    fn renderInput(self: *Renderer, cx: *gooey.Cx, artifact: *Artifact, state: *core.RuntimeState, revision: u32, node_index: u8, candidate_index: u8, id: []const u8, props: core.InputProps) !void {
        const state_index = state.find(props.state_id) orelse return error.UnknownStateId;
        if (state.entries[state_index].value != .text) return error.WrongStateType;
        const scratch = &artifact.input_scratch[candidate_index];
        const state_text = try state.text(state_index);
        try syncInputScratch(scratch, state_index, state_text);
        bindValue(self, artifact, state, scratch, revision, node_index, candidate_index, state_index);
        cx.render(gooey.components.TextInput{
            .id = id,
            .placeholder = props.placeholder,
            .disabled = props.disabled,
            .max_bytes = core.state_text_bytes_max,
            .bind = &scratch.view,
            .on_blur = valueHandler(&artifact.value_bindings[candidate_index], emitTextValue),
        });
    }

    fn renderCheckbox(self: *Renderer, cx: *gooey.Cx, artifact: *Artifact, state: *core.RuntimeState, revision: u32, node_index: u8, candidate_index: u8, id: []const u8, props: core.CheckboxProps) !void {
        const state_index = state.find(props.state_id) orelse return error.UnknownStateId;
        if (state.entries[state_index].value != .boolean) return error.WrongStateType;
        bindValue(self, artifact, state, null, revision, node_index, candidate_index, state_index);
        cx.render(gooey.components.Checkbox{
            .id = id,
            .selected = state.entries[state_index].value.boolean,
            .label = props.label,
            .on_click_handler = valueHandler(&artifact.value_bindings[candidate_index], toggleBoolean),
        });
    }

    pub fn popEvent(self: *Renderer) ?ActionEvent {
        std.debug.assert(self.event_count <= core.events_max);
        std.debug.assert(self.event_head < core.events_max);
        if (self.event_count == 0) return null;
        const event = self.events[self.event_head];
        self.event_head = (self.event_head + 1) % core.events_max;
        self.event_count -= 1;
        return event;
    }

    pub fn popValueEvent(self: *Renderer) ?ValueEvent {
        std.debug.assert(self.value_event_count <= core.events_max);
        std.debug.assert(self.value_event_head < core.events_max);
        if (self.value_event_count == 0) return null;
        const event = self.value_events[self.value_event_head];
        self.value_event_head = (self.value_event_head + 1) % core.events_max;
        self.value_event_count -= 1;
        return event;
    }

    pub fn takeEventOverflow(self: *Renderer) bool {
        const result = self.event_overflowed;
        self.event_overflowed = false;
        return result;
    }

    pub fn takeValueEventOverflow(self: *Renderer) bool {
        const result = self.value_event_overflowed;
        self.value_event_overflowed = false;
        return result;
    }

    pub fn takeBindingFailure(self: *Renderer) bool {
        const result = self.binding_failed;
        self.binding_failed = false;
        return result;
    }
};

fn bindAction(renderer: *Renderer, artifact: *Artifact, revision: u32, node_index: u8, candidate_index: u8, action: u8) void {
    std.debug.assert(node_index < core.nodes_max);
    std.debug.assert(candidate_index < core.candidates_max);
    artifact.action_bindings[candidate_index] = .{ .renderer = renderer, .event = .{ .artifact_id = artifact.id, .revision = revision, .node_index = node_index, .action_tag = action } };
}

fn bindValue(renderer: *Renderer, artifact: *Artifact, state: *core.RuntimeState, scratch: ?*InputScratch, revision: u32, node_index: u8, candidate_index: u8, state_index: u8) void {
    std.debug.assert(node_index < core.nodes_max);
    std.debug.assert(state_index < state.count);
    artifact.value_bindings[candidate_index] = .{ .renderer = renderer, .artifact_id = artifact.id, .state = state, .scratch = scratch, .revision = revision, .node_index = node_index, .state_index = state_index };
}

fn actionHandler(binding: *ActionBinding) gooey.ui.HandlerRef {
    std.debug.assert(@intFromPtr(binding.renderer) != 0);
    std.debug.assert(binding.event.node_index < core.nodes_max);
    return .{ .callback = emitAction, .entity_id = gooey.context.packArg(*ActionBinding, binding) };
}

fn valueHandler(binding: *ValueBinding, callback: *const fn (*gooey.Window, gooey.context.EntityId) void) gooey.ui.HandlerRef {
    std.debug.assert(@intFromPtr(binding.renderer) != 0);
    std.debug.assert(@intFromPtr(binding.state) != 0);
    return .{ .callback = callback, .entity_id = gooey.context.packArg(*ValueBinding, binding) };
}

fn emitAction(window: *gooey.Window, entity_id: gooey.context.EntityId) void {
    const binding = gooey.context.unpackArg(*ActionBinding, entity_id);
    enqueueAction(binding);
    window.requestRender();
}

fn emitTextValue(window: *gooey.Window, entity_id: gooey.context.EntityId) void {
    const binding = gooey.context.unpackArg(*ValueBinding, entity_id);
    commitTextValue(binding);
    window.requestRender();
}

fn toggleBoolean(window: *gooey.Window, entity_id: gooey.context.EntityId) void {
    const binding = gooey.context.unpackArg(*ValueBinding, entity_id);
    toggleBooleanValue(binding);
    window.requestRender();
}

fn commitTextValue(binding: *ValueBinding) void {
    const scratch = binding.scratch orelse unreachable;
    binding.state.setText(binding.state_index, scratch.view) catch {
        binding.renderer.binding_failed = true;
        return;
    };
    enqueueValue(binding);
    scratch.set(binding.state_index, binding.state.text(binding.state_index) catch unreachable) catch unreachable;
}

fn toggleBooleanValue(binding: *ValueBinding) void {
    const value = &binding.state.entries[binding.state_index].value;
    std.debug.assert(value.* == .boolean);
    std.debug.assert(binding.scratch == null);
    value.boolean = !value.boolean;
    enqueueValue(binding);
}

fn enqueueAction(binding: *ActionBinding) void {
    const renderer = binding.renderer;
    std.debug.assert(binding.event.node_index < core.nodes_max);
    std.debug.assert(renderer.event_count <= core.events_max);
    if (renderer.event_count >= core.events_max) {
        renderer.event_overflowed = true;
        return;
    }
    const tail = (renderer.event_head + renderer.event_count) % core.events_max;
    renderer.events[tail] = binding.event;
    renderer.event_count += 1;
}

fn enqueueValue(binding: *ValueBinding) void {
    const renderer = binding.renderer;
    std.debug.assert(binding.node_index < core.nodes_max);
    std.debug.assert(binding.state_index < binding.state.count);
    if (renderer.value_event_count >= core.events_max) {
        renderer.value_event_overflowed = true;
        return;
    }
    const tail = (renderer.value_event_head + renderer.value_event_count) % core.events_max;
    renderer.value_events[tail] = .{ .artifact_id = binding.artifact_id, .revision = binding.revision, .node_index = binding.node_index, .state_index = binding.state_index, .value = binding.state.entries[binding.state_index].value };
    renderer.value_event_count += 1;
}

fn beginContainer(cx: *gooey.Cx, id: []const u8, props: core.Props) !void {
    std.debug.assert(id.len > 0);
    std.debug.assert(core.canContainChildren(props));
    const layout_id = gooey.layout.LayoutId.fromString(id);
    switch (props) {
        .stack => |value| try cx.dynamic.beginBox(layout_id, .{ .direction = .column, .gap = value.gap }),
        .row => |value| try cx.dynamic.beginBox(layout_id, .{ .direction = .row, .gap = value.gap, .alignment = .{ .cross = .center } }),
        .card => |value| try cx.dynamic.beginBox(layout_id, .{ .direction = .column, .gap = value.gap, .padding = .{ .all = value.padding }, .background = cx.theme().surface, .border_color = cx.theme().border, .border_width = .{ .all = 1 }, .corner_radius = cx.theme().radius_md }),
        .text, .button, .input, .checkbox => unreachable,
    }
}

fn pushContainerFrames(spec: *const core.Spec, frame: Renderer.Frame, stack: *[core.nodes_max * 2]Renderer.Frame, stack_count: *u8) !void {
    std.debug.assert(frame.node_index < spec.node_count);
    std.debug.assert(stack_count.* < stack.len);
    stack[stack_count.*] = .{ .node_index = frame.node_index, .exit = true, .depth = frame.depth };
    stack_count.* += 1;
    var children: [core.nodes_max]u8 = undefined;
    var child_count: u8 = 0;
    var child = spec.nodes[frame.node_index].first_child_index;
    while (child) |index| {
        if (child_count >= core.nodes_max) return error.TraversalCapacityExceeded;
        children[child_count] = index;
        child_count += 1;
        child = spec.nodes[index].next_sibling_index;
    }
    while (child_count > 0) {
        child_count -= 1;
        if (stack_count.* >= stack.len) return error.TraversalCapacityExceeded;
        stack[stack_count.*] = .{ .node_index = children[child_count], .exit = false, .depth = frame.depth + 1 };
        stack_count.* += 1;
    }
}

fn closeBoxes(cx: *gooey.Cx, boxes_open: *u8) void {
    std.debug.assert(boxes_open.* <= core.depth_max);
    std.debug.assert(@intFromPtr(cx) != 0);
    while (boxes_open.* > 0) {
        cx.dynamic.endBox();
        boxes_open.* -= 1;
    }
}

test "queued text events own distinct snapshots after later edits" {
    var renderer = Renderer{};
    var artifact = try Artifact.init("chat-a");
    var state = core.RuntimeState{};
    const state_index = try state.add("name", .{ .text = "initial" });
    const scratch = &artifact.input_scratch[0];
    try scratch.set(state_index, "first");
    bindValue(&renderer, &artifact, &state, scratch, 1, 2, 0, state_index);
    commitTextValue(&artifact.value_bindings[0]);
    try scratch.set(state_index, "second-longer");
    commitTextValue(&artifact.value_bindings[0]);
    try state.setText(state_index, "third");

    const first = renderer.popValueEvent().?;
    const second = renderer.popValueEvent().?;
    try std.testing.expectEqualStrings("first", first.value.text.slice());
    try std.testing.expectEqualStrings("second-longer", second.value.text.slice());
    try std.testing.expectEqualStrings("third", try state.text(state_index));
}

test "owned input scratch follows external state without overwriting active widget text" {
    var scratch = InputScratch{};
    try syncInputScratch(&scratch, 2, "Ada");
    try syncInputScratch(&scratch, 2, "Ada Lovelace");
    try std.testing.expectEqualStrings("Ada Lovelace", scratch.view);

    const active_widget_text = "User editing";
    scratch.view = active_widget_text;
    try syncInputScratch(&scratch, 2, "External update");
    try std.testing.expectEqualStrings(active_widget_text, scratch.view);
}

test "artifact namespaces isolate duplicate keys and survive node moves" {
    var renderer = Renderer{};
    var first = try Artifact.init("message-1");
    var second = try Artifact.init("message-2");
    const keys = [_][]const u8{ "root", "name", "save" };
    for (keys, 0..) |key, index| {
        const first_id = try first.controlId(@intCast(index), key);
        const second_id = try second.controlId(@intCast(index), key);
        try std.testing.expect(!std.mem.eql(u8, first_id, second_id));
    }
    try std.testing.expectEqualStrings("message-1/save", try first.controlId(2, "save"));

    bindAction(&renderer, &first, 1, 2, 2, 0);
    const binding_address = @intFromPtr(&first.action_bindings[2]);
    bindAction(&renderer, &second, 1, 2, 2, 0);
    try std.testing.expectEqualStrings("message-1", first.action_bindings[2].event.artifact_id.slice());
    bindAction(&renderer, &first, 2, 7, 2, 0);
    try std.testing.expectEqual(binding_address, @intFromPtr(&first.action_bindings[2]));
    try std.testing.expectEqual(@as(u8, 7), first.action_bindings[2].event.node_index);
    try std.testing.expectEqualStrings("message-1/save", try first.controlId(2, "save"));
}

test "artifact delimiter contract rejects formerly colliding namespace" {
    try std.testing.expectError(error.InvalidArtifactId, Artifact.init("a/b"));
    var artifact = try Artifact.init("a");
    try std.testing.expectEqualStrings("a/b/c", try artifact.controlId(0, "b/c"));
}

test "artifact pins one renderer owner while callbacks may exist" {
    var first_renderer = Renderer{};
    var second_renderer = Renderer{};
    var artifact = try Artifact.init("owned");
    var candidates = core.CandidateSet{};
    try artifact.attach(&first_renderer, &candidates);
    try artifact.attach(&first_renderer, &candidates);
    try std.testing.expectError(error.ArtifactRendererMismatch, artifact.attach(&second_renderer, &candidates));
    var moved_renderer = first_renderer;
    try std.testing.expectError(error.RendererMoved, moved_renderer.ensureStable());
}

test "full action queue reports overflow without replacing earlier events" {
    var renderer = Renderer{};
    var artifact = try Artifact.init("actions");
    bindAction(&renderer, &artifact, 9, 3, 0, 2);
    var event_count: u8 = 0;
    while (event_count < core.events_max + 1) : (event_count += 1) enqueueAction(&artifact.action_bindings[0]);
    try std.testing.expect(renderer.takeEventOverflow());
    try std.testing.expectEqual(@as(u8, core.events_max), renderer.event_count);
    const first = renderer.popEvent().?;
    try std.testing.expectEqual(@as(u32, 9), first.revision);
    try std.testing.expectEqual(@as(u8, 2), first.action_tag);
}

test "full value queue preserves ordering and reports overflow" {
    var renderer = Renderer{};
    var artifact = try Artifact.init("queue");
    var state = core.RuntimeState{};
    const enabled = try state.add("enabled", .{ .boolean = false });
    bindValue(&renderer, &artifact, &state, null, 4, 0, 0, enabled);
    var event_count: u8 = 0;
    while (event_count < core.events_max + 1) : (event_count += 1) {
        state.entries[enabled].value.boolean = event_count % 2 == 0;
        enqueueValue(&artifact.value_bindings[0]);
    }
    try std.testing.expect(renderer.takeValueEventOverflow());
    try std.testing.expect(renderer.popValueEvent().?.value.boolean);
    try std.testing.expect(!renderer.popValueEvent().?.value.boolean);
}
