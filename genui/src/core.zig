const std = @import("std");

pub const candidates_max = 32;
pub const nodes_max = 14;
pub const depth_max = 4;
pub const actions_max = 8;
pub const events_max = 32;
pub const state_entries_max = 16;
pub const key_bytes_max = 48;
pub const state_text_bytes_max = 256;
pub const prop_text_bytes_max = 256;

pub fn BoundedString(comptime capacity: u16) type {
    return struct {
        bytes: [capacity]u8 = [_]u8{0} ** capacity,
        len: u16 = 0,

        const Self = @This();

        pub fn init(value: []const u8) !Self {
            var result = Self{};
            try result.set(value);
            return result;
        }

        pub fn set(self: *Self, value: []const u8) !void {
            std.debug.assert(self.len <= capacity);
            std.debug.assert(capacity <= std.math.maxInt(u16));
            if (value.len > capacity) return error.StringTooLong;
            // Copy before assigning so `value` may be this string or any of
            // its subslices without zeroing or overlapping the source.
            var replacement = Self{};
            @memcpy(replacement.bytes[0..value.len], value);
            replacement.len = @intCast(value.len);
            self.* = replacement;
        }

        pub fn slice(self: *const Self) []const u8 {
            std.debug.assert(self.len <= capacity);
            std.debug.assert(capacity <= std.math.maxInt(u16));
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const Self, value: []const u8) bool {
            std.debug.assert(self.len <= capacity);
            std.debug.assert(value.len <= std.math.maxInt(u16));
            return std.mem.eql(u8, self.slice(), value);
        }
    };
}

pub const Key = BoundedString(key_bytes_max);
pub const TextValue = BoundedString(state_text_bytes_max);
pub const PropText = BoundedString(prop_text_bytes_max);

pub const Component = enum(u8) { stack, row, card, text, button, input, checkbox };

pub const StackProps = struct { gap: f32 = 8 };
pub const RowProps = struct { gap: f32 = 8 };
pub const CardProps = struct { gap: f32 = 8, padding: f32 = 12 };
pub const TextProps = struct { content: []const u8 };
pub const ButtonProps = struct { label: []const u8, action: ?u8 = null };
pub const InputProps = struct {
    placeholder: []const u8 = "",
    state_id: []const u8,
    disabled: bool = false,
};
pub const CheckboxProps = struct {
    label: []const u8,
    state_id: []const u8,
};

pub const Props = union(Component) {
    stack: StackProps,
    row: RowProps,
    card: CardProps,
    text: TextProps,
    button: ButtonProps,
    input: InputProps,
    checkbox: CheckboxProps,
};

pub const StateInput = union(enum) {
    boolean: bool,
    text: []const u8,
};

pub const StateValue = union(enum) {
    boolean: bool,
    text: TextValue,
};

pub const StateEntry = struct {
    id: Key,
    value: StateValue,
};

pub const RuntimeState = struct {
    entries: [state_entries_max]StateEntry = undefined,
    count: u8 = 0,

    pub fn add(self: *RuntimeState, id: []const u8, value: StateInput) !u8 {
        std.debug.assert(self.count <= state_entries_max);
        std.debug.assert(@sizeOf(StateEntry) > @sizeOf(StateValue));
        if (id.len == 0 or id.len > key_bytes_max) return error.InvalidStateId;
        if (self.count >= state_entries_max) return error.StateCapacityExceeded;
        if (value == .text and value.text.len > state_text_bytes_max) return error.StateTextTooLong;
        if (self.find(id) != null) return error.DuplicateStateId;
        const index = self.count;
        self.entries[index].id = Key.init(id) catch return error.InvalidStateId;
        self.entries[index].value = switch (value) {
            .boolean => |boolean| .{ .boolean = boolean },
            .text => |text_input| .{ .text = TextValue.init(text_input) catch return error.StateTextTooLong },
        };
        self.count += 1;
        return index;
    }

    pub fn find(self: *const RuntimeState, id: []const u8) ?u8 {
        std.debug.assert(self.count <= state_entries_max);
        std.debug.assert(id.len <= key_bytes_max);
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.id.eql(id)) return @intCast(index);
        }
        return null;
    }

    pub fn setBoolean(self: *RuntimeState, index: u8, value: bool) !void {
        std.debug.assert(self.count <= state_entries_max);
        std.debug.assert(index <= std.math.maxInt(u8));
        if (index >= self.count) return error.InvalidStateIndex;
        if (self.entries[index].value != .boolean) return error.WrongStateType;
        self.entries[index].value.boolean = value;
    }

    pub fn setText(self: *RuntimeState, index: u8, value: []const u8) !void {
        std.debug.assert(self.count <= state_entries_max);
        std.debug.assert(index <= std.math.maxInt(u8));
        if (index >= self.count) return error.InvalidStateIndex;
        if (self.entries[index].value != .text) return error.WrongStateType;
        if (value.len > state_text_bytes_max) return error.StateTextTooLong;
        self.entries[index].value.text.set(value) catch return error.StateTextTooLong;
    }

    pub fn text(self: *const RuntimeState, index: u8) ![]const u8 {
        std.debug.assert(self.count <= state_entries_max);
        std.debug.assert(index <= std.math.maxInt(u8));
        if (index >= self.count) return error.InvalidStateIndex;
        if (self.entries[index].value != .text) return error.WrongStateType;
        return self.entries[index].value.text.slice();
    }
};

pub const Catalog = struct {
    actions: [actions_max]Key = undefined,
    action_count: u8 = 0,

    pub fn addAction(self: *Catalog, name: []const u8) error{ CapacityExceeded, InvalidName, DuplicateName }!u8 {
        if (name.len == 0 or name.len > key_bytes_max) return error.InvalidName;
        if (self.action_count >= actions_max) return error.CapacityExceeded;
        for (self.actions[0..self.action_count]) |existing| {
            if (existing.eql(name)) return error.DuplicateName;
        }
        const tag = self.action_count;
        self.actions[tag] = Key.init(name) catch return error.InvalidName;
        self.action_count += 1;
        return tag;
    }

    pub fn permits(self: *const Catalog, tag: u8) bool {
        std.debug.assert(self.action_count <= actions_max);
        std.debug.assert(tag <= std.math.maxInt(u8));
        return tag < self.action_count;
    }

    pub fn actionName(self: *const Catalog, tag: u8) ![]const u8 {
        std.debug.assert(self.action_count <= actions_max);
        std.debug.assert(tag <= std.math.maxInt(u8));
        if (!self.permits(tag)) return error.UnknownAction;
        return self.actions[tag].slice();
    }
};

pub const Candidate = struct {
    key: []const u8,
    props: Props,
    can_be_root: bool = false,
};

const CandidateStorage = struct {
    key: Key = .{},
    content: PropText = .{},
    label: PropText = .{},
    placeholder: PropText = .{},
    state_id: Key = .{},
};

pub const CandidateSet = struct {
    // Stored slices point into `storage`. The first insertion pins this value;
    // every composition/render entry point rejects a later struct move.
    items: [candidates_max]Candidate = undefined,
    storage: [candidates_max]CandidateStorage = [_]CandidateStorage{.{}} ** candidates_max,
    count: u8 = 0,
    pinned_address: usize = 0,

    pub fn add(self: *CandidateSet, catalog: *const Catalog, candidate: Candidate) !u8 {
        try self.ensureStable();
        if (candidate.key.len == 0 or candidate.key.len > key_bytes_max) return error.InvalidKey;
        if (self.count >= candidates_max) return error.CapacityExceeded;
        for (self.items[0..self.count]) |existing| {
            if (std.mem.eql(u8, existing.key, candidate.key)) return error.DuplicateKey;
        }
        switch (candidate.props) {
            .button => |props| {
                const tag = props.action orelse return error.UnknownAction;
                if (!catalog.permits(tag)) return error.UnknownAction;
            },
            else => {},
        }
        const index = self.count;
        self.items[index] = try storeCandidate(&self.storage[index], candidate);
        self.count += 1;
        return index;
    }

    pub fn ensureStable(self: *const CandidateSet) !void {
        const address = @intFromPtr(self);
        if (self.pinned_address == 0) {
            @constCast(self).pinned_address = address;
        } else {
            if (self.pinned_address != address) return error.CandidateSetMoved;
        }
    }

    pub fn setTextContent(self: *CandidateSet, index: u8, content: []const u8) !void {
        try self.ensureStable();
        if (index >= self.count) return error.InvalidCandidate;
        if (self.items[index].props != .text) return error.WrongComponentType;
        self.storage[index].content.set(content) catch return error.InvalidProperty;
        self.items[index].props.text.content = self.storage[index].content.slice();
    }
};

fn storeCandidate(storage: *CandidateStorage, candidate: Candidate) !Candidate {
    storage.key.set(candidate.key) catch return error.InvalidKey;
    const props: Props = switch (candidate.props) {
        .stack => |value| .{ .stack = value },
        .row => |value| .{ .row = value },
        .card => |value| .{ .card = value },
        .text => |value| blk: {
            storage.content.set(value.content) catch return error.InvalidProperty;
            break :blk .{ .text = .{ .content = storage.content.slice() } };
        },
        .button => |value| blk: {
            storage.label.set(value.label) catch return error.InvalidProperty;
            break :blk .{ .button = .{ .label = storage.label.slice(), .action = value.action } };
        },
        .input => |value| blk: {
            storage.placeholder.set(value.placeholder) catch return error.InvalidProperty;
            storage.state_id.set(value.state_id) catch return error.InvalidStateId;
            break :blk .{ .input = .{ .placeholder = storage.placeholder.slice(), .state_id = storage.state_id.slice(), .disabled = value.disabled } };
        },
        .checkbox => |value| blk: {
            storage.label.set(value.label) catch return error.InvalidProperty;
            storage.state_id.set(value.state_id) catch return error.InvalidStateId;
            break :blk .{ .checkbox = .{ .label = storage.label.slice(), .state_id = storage.state_id.slice() } };
        },
    };
    return .{ .key = storage.key.slice(), .props = props, .can_be_root = candidate.can_be_root };
}

pub const Node = struct {
    candidate_index: u8,
    parent_index: ?u8,
    first_child_index: ?u8 = null,
    next_sibling_index: ?u8 = null,
};

pub const Spec = struct {
    nodes: [nodes_max]Node = undefined,
    node_count: u8 = 0,
    root_index: ?u8 = null,
    revision: u32 = 0,
};

pub const Selection = struct {
    selected: [candidates_max]bool = [_]bool{false} ** candidates_max,
    root_candidate: u8 = 0,
};

pub const Layout = struct {
    parent_candidate: [candidates_max]?u8 = [_]?u8{null} ** candidates_max,
    order: [candidates_max]u8 = [_]u8{0} ** candidates_max,
};

pub const EvaluationRequest = union(enum) {
    selection: *const CandidateSet,
    layout: struct { candidates: *const CandidateSet, selection: *const Selection },
};

pub const EvaluationResponse = union(enum) { selection: Selection, layout: Layout };

pub const Evaluator = struct {
    context: *anyopaque,
    evaluate_fn: *const fn (*anyopaque, *const EvaluationRequest, *EvaluationResponse) anyerror!void,

    pub fn evaluate(self: Evaluator, request: *const EvaluationRequest, response: *EvaluationResponse) !void {
        std.debug.assert(@intFromPtr(self.context) != 0);
        std.debug.assert(@intFromPtr(self.evaluate_fn) != 0);
        try self.evaluate_fn(self.context, request, response);
    }
};

pub fn compose(evaluator: Evaluator, candidates: *const CandidateSet, revision: u32, output: *Spec) !void {
    std.debug.assert(candidates.count > 0);
    std.debug.assert(candidates.count <= candidates_max);
    try candidates.ensureStable();
    var selection_response: EvaluationResponse = undefined;
    const selection_request = EvaluationRequest{ .selection = candidates };
    try evaluator.evaluate(&selection_request, &selection_response);
    if (selection_response != .selection) return error.WrongEvaluationStage;

    var layout_response: EvaluationResponse = undefined;
    const layout_request = EvaluationRequest{ .layout = .{ .candidates = candidates, .selection = &selection_response.selection } };
    try evaluator.evaluate(&layout_request, &layout_response);
    if (layout_response != .layout) return error.WrongEvaluationStage;

    var scratch = Spec{};
    try buildSpec(candidates, &selection_response.selection, &layout_response.layout, revision, &scratch);
    output.* = scratch;
}

fn buildSpec(candidates: *const CandidateSet, selection: *const Selection, layout: *const Layout, revision: u32, output: *Spec) !void {
    if (selection.root_candidate >= candidates.count) return error.InvalidRoot;
    if (!selection.selected[selection.root_candidate]) return error.InvalidRoot;
    if (!candidates.items[selection.root_candidate].can_be_root) return error.InvalidRoot;

    var candidate_to_node = [_]?u8{null} ** candidates_max;
    for (0..candidates.count) |candidate_index| {
        if (!selection.selected[candidate_index]) continue;
        if (output.node_count >= nodes_max) return error.NodeCapacityExceeded;
        const node_index = output.node_count;
        output.nodes[node_index] = .{ .candidate_index = @intCast(candidate_index), .parent_index = null };
        candidate_to_node[candidate_index] = node_index;
        output.node_count += 1;
    }
    output.root_index = candidate_to_node[selection.root_candidate];
    output.revision = revision;

    for (0..candidates.count) |candidate_index| {
        const node_index = candidate_to_node[candidate_index] orelse continue;
        if (candidate_index == selection.root_candidate) continue;
        const parent_candidate = layout.parent_candidate[candidate_index] orelse return error.MissingParent;
        if (parent_candidate >= candidates.count) return error.InvalidParent;
        const parent_node = candidate_to_node[parent_candidate] orelse return error.InvalidParent;
        if (!canContainChildren(candidates.items[parent_candidate].props)) return error.ParentCannotContainChildren;
        output.nodes[node_index].parent_index = parent_node;
    }
    try linkNodes(output, layout);
    try validateSpec(candidates, output);
}

fn linkNodes(spec: *Spec, layout: *const Layout) !void {
    for (0..spec.node_count) |parent_index| {
        var child_indexes: [nodes_max]u8 = undefined;
        var child_count: u8 = 0;
        for (0..spec.node_count) |node_index| {
            if (spec.nodes[node_index].parent_index == @as(u8, @intCast(parent_index))) {
                child_indexes[child_count] = @intCast(node_index);
                child_count += 1;
            }
        }
        var unsorted_index: u8 = 1;
        while (unsorted_index < child_count) : (unsorted_index += 1) {
            const moving = child_indexes[unsorted_index];
            var sorted_index = unsorted_index;
            while (sorted_index > 0) {
                const previous = child_indexes[sorted_index - 1];
                if (layout.order[spec.nodes[previous].candidate_index] <= layout.order[spec.nodes[moving].candidate_index]) break;
                child_indexes[sorted_index] = previous;
                sorted_index -= 1;
            }
            child_indexes[sorted_index] = moving;
        }
        if (child_count > 0) spec.nodes[parent_index].first_child_index = child_indexes[0];
        if (child_count > 1) {
            for (1..child_count) |index| {
                const previous_order = layout.order[spec.nodes[child_indexes[index - 1]].candidate_index];
                const current_order = layout.order[spec.nodes[child_indexes[index]].candidate_index];
                if (previous_order == current_order) return error.DuplicateOrder;
                spec.nodes[child_indexes[index - 1]].next_sibling_index = child_indexes[index];
            }
        }
    }
}

pub fn validateSpec(candidates: *const CandidateSet, spec: *const Spec) !void {
    try candidates.ensureStable();
    if (spec.node_count == 0 or spec.node_count > nodes_max) return error.InvalidNodeCount;
    if (candidates.count == 0 or candidates.count > candidates_max) return error.InvalidCandidateCount;
    const root = spec.root_index orelse return error.InvalidRoot;
    if (root >= spec.node_count) return error.InvalidRoot;
    for (spec.nodes[0..spec.node_count]) |node| {
        if (node.candidate_index >= candidates.count) return error.InvalidCandidate;
    }
    if (spec.nodes[root].parent_index != null) return error.InvalidRootParent;
    if (spec.nodes[root].next_sibling_index != null) return error.InvalidRootSibling;
    const root_candidate = spec.nodes[root].candidate_index;
    if (!candidates.items[root_candidate].can_be_root) return error.InvalidRoot;
    try validateRelationships(candidates, spec);
    try validateDepthAndReachability(spec, root);
}

fn validateRelationships(candidates: *const CandidateSet, spec: *const Spec) !void {
    std.debug.assert(spec.node_count > 0);
    std.debug.assert(spec.node_count <= nodes_max);
    var candidate_seen = [_]bool{false} ** candidates_max;
    for (spec.nodes[0..spec.node_count]) |node| {
        if (candidate_seen[node.candidate_index]) return error.DuplicateCandidate;
        candidate_seen[node.candidate_index] = true;
        if (node.first_child_index) |child| {
            if (child >= spec.node_count) return error.InvalidChild;
        }
        if (node.next_sibling_index) |sibling| {
            if (sibling >= spec.node_count) return error.InvalidChild;
        }
        if (node.parent_index) |parent| {
            if (parent >= spec.node_count) return error.InvalidParent;
            const parent_candidate = spec.nodes[parent].candidate_index;
            if (!canContainChildren(candidates.items[parent_candidate].props)) return error.ParentCannotContainChildren;
        }
    }
}

pub fn validateCatalogBindings(catalog: *const Catalog, state: ?*const RuntimeState, candidates: *const CandidateSet) !void {
    std.debug.assert(catalog.action_count <= actions_max);
    std.debug.assert(candidates.count <= candidates_max);
    try candidates.ensureStable();
    for (candidates.items[0..candidates.count]) |candidate| {
        switch (candidate.props) {
            .button => |props| {
                const action = props.action orelse return error.UnknownAction;
                if (!catalog.permits(action)) return error.UnknownAction;
            },
            .input => |props| try validateStateReference(state, props.state_id, .text),
            .checkbox => |props| try validateStateReference(state, props.state_id, .boolean),
            else => {},
        }
    }
}

fn validateStateReference(state_optional: ?*const RuntimeState, id: []const u8, expected: std.meta.Tag(StateValue)) !void {
    if (id.len == 0 or id.len > key_bytes_max) return error.InvalidStateId;
    const state = state_optional orelse return error.MissingRuntimeState;
    const index = state.find(id) orelse return error.UnknownStateId;
    if (std.meta.activeTag(state.entries[index].value) != expected) return error.WrongStateType;
}

pub fn canContainChildren(props: Props) bool {
    std.debug.assert(@intFromEnum(std.meta.activeTag(props)) <= @intFromEnum(Component.checkbox));
    std.debug.assert(@sizeOf(Props) > 0);
    return switch (props) {
        .stack, .row, .card => true,
        .text, .button, .input, .checkbox => false,
    };
}

fn validateDepthAndReachability(spec: *const Spec, root: u8) !void {
    const Entry = struct { node: u8, parent: ?u8, depth: u8 };
    var stack: [nodes_max]Entry = undefined;
    var seen = [_]bool{false} ** nodes_max;
    var count: u8 = 1;
    stack[0] = .{ .node = root, .parent = null, .depth = 1 };
    while (count > 0) {
        count -= 1;
        const entry = stack[count];
        if (seen[entry.node]) return error.CycleOrSharedNode;
        if (entry.depth > depth_max) return error.DepthExceeded;
        if (spec.nodes[entry.node].parent_index != entry.parent) return error.InvalidParent;
        seen[entry.node] = true;
        var child = spec.nodes[entry.node].first_child_index;
        while (child) |child_index| {
            if (child_index >= spec.node_count) return error.InvalidChild;
            if (count >= nodes_max) return error.NodeCapacityExceeded;
            stack[count] = .{ .node = child_index, .parent = entry.node, .depth = entry.depth + 1 };
            count += 1;
            child = spec.nodes[child_index].next_sibling_index;
        }
    }
    for (seen[0..spec.node_count]) |visited| if (!visited) return error.UnreachableNode;
}

test "scripted evaluator deterministically composes selection and layout" {
    var catalog = Catalog{};
    const save = try catalog.addAction("save");
    var candidates = CandidateSet{};
    const stack = try candidates.add(&catalog, .{ .key = "root", .props = .{ .stack = .{ .gap = 12 } }, .can_be_root = true });
    const text = try candidates.add(&catalog, .{ .key = "title", .props = .{ .text = .{ .content = "Profile" } } });
    const button = try candidates.add(&catalog, .{ .key = "save", .props = .{ .button = .{ .label = "Save", .action = save } } });
    const Script = struct {
        stack: u8,
        text: u8,
        button: u8,
        calls: u8 = 0,
        fn evaluate(pointer: *anyopaque, request: *const EvaluationRequest, response: *EvaluationResponse) !void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.calls += 1;
            switch (request.*) {
                .selection => {
                    var selection = Selection{ .root_candidate = self.stack };
                    selection.selected[self.stack] = true;
                    selection.selected[self.text] = true;
                    selection.selected[self.button] = true;
                    response.* = .{ .selection = selection };
                },
                .layout => {
                    var layout = Layout{};
                    layout.parent_candidate[self.text] = self.stack;
                    layout.parent_candidate[self.button] = self.stack;
                    layout.order[self.text] = 0;
                    layout.order[self.button] = 1;
                    response.* = .{ .layout = layout };
                },
            }
        }
    };
    var script = Script{ .stack = stack, .text = text, .button = button };
    var spec = Spec{};
    try compose(.{ .context = &script, .evaluate_fn = Script.evaluate }, &candidates, 7, &spec);
    try std.testing.expectEqual(@as(u8, 2), script.calls);
    try std.testing.expectEqual(@as(u32, 7), spec.revision);
    try std.testing.expectEqual(text, spec.nodes[spec.nodes[spec.root_index.?].first_child_index.?].candidate_index);
}

test "candidate set rejects Button actions outside the catalog" {
    const catalog = Catalog{};
    var candidates = CandidateSet{};
    try std.testing.expectError(error.UnknownAction, candidates.add(&catalog, .{
        .key = "unsafe",
        .props = .{ .button = .{ .label = "Unsafe", .action = 0 } },
    }));
    try std.testing.expectError(error.UnknownAction, candidates.add(&catalog, .{
        .key = "missing",
        .props = .{ .button = .{ .label = "Missing" } },
    }));
}

test "runtime validation rejects a malformed child link" {
    const catalog = Catalog{};
    var candidates = CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = "root", .props = .{ .stack = .{} }, .can_be_root = true });
    var spec = Spec{ .node_count = 1, .root_index = 0 };
    spec.nodes[0] = .{ .candidate_index = 0, .parent_index = null, .first_child_index = 1 };
    try std.testing.expectError(error.InvalidChild, validateSpec(&candidates, &spec));
}

test "runtime validation rejects duplicate candidate instances" {
    const catalog = Catalog{};
    var candidates = CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = "root", .props = .{ .stack = .{} }, .can_be_root = true });
    var spec = Spec{ .node_count = 2, .root_index = 0 };
    spec.nodes[0] = .{ .candidate_index = 0, .parent_index = null, .first_child_index = 1 };
    spec.nodes[1] = .{ .candidate_index = 0, .parent_index = 0 };
    try std.testing.expectError(error.DuplicateCandidate, validateSpec(&candidates, &spec));
}

test "catalog binding validation rejects unknown and mistyped state ids" {
    const catalog = Catalog{};
    var state = RuntimeState{};
    _ = try state.add("name", .{ .text = "Grace" });
    _ = try state.add("enabled", .{ .boolean = true });

    var unknown = CandidateSet{};
    _ = try unknown.add(&catalog, .{ .key = "email", .props = .{ .input = .{ .state_id = "missing" } } });
    try std.testing.expectError(error.UnknownStateId, validateCatalogBindings(&catalog, &state, &unknown));

    var mistyped = CandidateSet{};
    _ = try mistyped.add(&catalog, .{ .key = "wrong", .props = .{ .checkbox = .{ .label = "Wrong", .state_id = "name" } } });
    try std.testing.expectError(error.WrongStateType, validateCatalogBindings(&catalog, &state, &mistyped));
}

test "runtime state rejects invalid ids and updates only matching types" {
    var state = RuntimeState{};
    const title = try state.add("title", .{ .text = "Before" });
    const visible = try state.add("visible", .{ .boolean = false });
    try std.testing.expectError(error.InvalidStateId, state.add("", .{ .boolean = true }));
    try std.testing.expectError(error.DuplicateStateId, state.add("title", .{ .text = "Duplicate" }));
    try std.testing.expectError(error.WrongStateType, state.setBoolean(title, true));
    try state.setText(title, "After");
    try state.setBoolean(visible, true);
    try std.testing.expectEqualStrings("After", state.entries[title].value.text.slice());
    try std.testing.expect(state.entries[visible].value.boolean);
}

test "row and card are containers while controls reject children" {
    const catalog = Catalog{};
    var candidates = CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = "card", .props = .{ .card = .{} }, .can_be_root = true });
    _ = try candidates.add(&catalog, .{ .key = "row", .props = .{ .row = .{} } });
    _ = try candidates.add(&catalog, .{ .key = "label", .props = .{ .text = .{ .content = "Value" } } });
    var spec = Spec{ .node_count = 3, .root_index = 0 };
    spec.nodes[0] = .{ .candidate_index = 0, .parent_index = null, .first_child_index = 1 };
    spec.nodes[1] = .{ .candidate_index = 1, .parent_index = 0, .first_child_index = 2 };
    spec.nodes[2] = .{ .candidate_index = 2, .parent_index = 1 };
    try validateSpec(&candidates, &spec);

    var leaves = CandidateSet{};
    _ = try leaves.add(&catalog, .{ .key = "leaf-root", .props = .{ .text = .{ .content = "Root" } }, .can_be_root = true });
    _ = try leaves.add(&catalog, .{ .key = "leaf-child", .props = .{ .text = .{ .content = "Child" } } });
    var invalid = Spec{ .node_count = 2, .root_index = 0 };
    invalid.nodes[0] = .{ .candidate_index = 0, .parent_index = null, .first_child_index = 1 };
    invalid.nodes[1] = .{ .candidate_index = 1, .parent_index = 0 };
    try std.testing.expectError(error.ParentCannotContainChildren, validateSpec(&leaves, &invalid));
}

test "catalog candidates and runtime state own caller bytes" {
    var action_bytes = [_]u8{ 's', 'a', 'v', 'e' };
    var catalog = Catalog{};
    _ = try catalog.addAction(&action_bytes);
    action_bytes[0] = 'X';
    try std.testing.expectEqualStrings("save", try catalog.actionName(0));

    var key_bytes = [_]u8{ 't', 'i', 't', 'l', 'e' };
    var content_bytes = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    var candidates = CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = &key_bytes, .props = .{ .text = .{ .content = &content_bytes } } });
    key_bytes[0] = 'X';
    content_bytes[0] = 'Y';
    try std.testing.expectEqualStrings("title", candidates.items[0].key);
    try std.testing.expectEqualStrings("Hello", candidates.items[0].props.text.content);
    try candidates.setTextContent(0, "Updated");
    try std.testing.expectEqualStrings("Updated", candidates.items[0].props.text.content);
    try candidates.setTextContent(0, candidates.items[0].props.text.content);
    try candidates.setTextContent(0, candidates.items[0].props.text.content[1..4]);
    try std.testing.expectEqualStrings("pda", candidates.items[0].props.text.content);
    for (candidates.storage[0].content.bytes[candidates.storage[0].content.len..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    var moved = candidates;
    try std.testing.expectError(error.CandidateSetMoved, moved.ensureStable());

    var id_bytes = [_]u8{ 'n', 'a', 'm', 'e' };
    var value_bytes = [_]u8{ 'A', 'd', 'a' };
    var state = RuntimeState{};
    const state_index = try state.add(&id_bytes, .{ .text = &value_bytes });
    id_bytes[0] = 'X';
    value_bytes[0] = 'Y';
    try std.testing.expectEqual(@as(?u8, state_index), state.find("name"));
    try std.testing.expectEqualStrings("Ada", try state.text(state_index));
    try state.setText(state_index, try state.text(state_index));
    try state.setText(state_index, (try state.text(state_index))[1..]);
    try std.testing.expectEqualStrings("da", try state.text(state_index));
    for (state.entries[state_index].value.text.bytes[state.entries[state_index].value.text.len..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "staged validation rejects invalid forward parent candidate before dereference" {
    const catalog = Catalog{};
    var candidates = CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = "root", .props = .{ .stack = .{} }, .can_be_root = true });
    _ = try candidates.add(&catalog, .{ .key = "child", .props = .{ .text = .{ .content = "Child" } } });
    var spec = Spec{ .node_count = 3, .root_index = 0 };
    spec.nodes[0] = .{ .candidate_index = 0, .parent_index = null, .first_child_index = 1 };
    spec.nodes[1] = .{ .candidate_index = 1, .parent_index = 2 };
    spec.nodes[2] = .{ .candidate_index = 255, .parent_index = 0 };
    try std.testing.expectError(error.InvalidCandidate, validateSpec(&candidates, &spec));
}

test "validation rejects root parent and sibling links" {
    const catalog = Catalog{};
    var candidates = CandidateSet{};
    _ = try candidates.add(&catalog, .{ .key = "root", .props = .{ .stack = .{} }, .can_be_root = true });
    _ = try candidates.add(&catalog, .{ .key = "child", .props = .{ .text = .{ .content = "Child" } } });
    var spec = Spec{ .node_count = 2, .root_index = 0 };
    spec.nodes[0] = .{ .candidate_index = 0, .parent_index = 1 };
    spec.nodes[1] = .{ .candidate_index = 1, .parent_index = 0 };
    try std.testing.expectError(error.InvalidRootParent, validateSpec(&candidates, &spec));
    spec.nodes[0].parent_index = null;
    spec.nodes[0].next_sibling_index = 1;
    try std.testing.expectError(error.InvalidRootSibling, validateSpec(&candidates, &spec));
}
