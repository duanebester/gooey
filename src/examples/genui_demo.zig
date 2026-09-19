const std = @import("std");
const gooey = @import("gooey");
const genui = @import("gooey-genui");

pub const std_options = gooey.std_options;

const ui = gooey.ui;
const core = genui.core;

const AppState = struct {
    catalog: core.Catalog = .{},
    candidates: core.CandidateSet = .{},
    runtime_state: core.RuntimeState = .{},
    spec: core.Spec = .{},
    artifact: genui.Artifact = genui.Artifact.initStatic("demo"),
    renderer: genui.Renderer = .{},
    status_buffer: [384]u8 = [_]u8{0} ** 384,
    status_candidate: u8 = 0,
    name_state: u8 = 0,
    enabled_state: u8 = 0,
    action_count: u32 = 0,
    value_count: u32 = 0,
    autoplay_frame: u16 = 0,
    autoplay: bool = false,
    initialized: bool = false,

    fn initialize(self: *AppState) !void {
        std.debug.assert(!self.initialized);
        std.debug.assert(self.candidates.count == 0);
        const action = try self.catalog.addAction("increment");
        self.name_state = try self.runtime_state.add("name", .{ .text = "Ada" });
        self.enabled_state = try self.runtime_state.add("enabled", .{ .boolean = true });
        const card = try self.candidates.add(&self.catalog, .{
            .key = "generated-card",
            .props = .{ .card = .{ .gap = 16, .padding = 24 } },
            .can_be_root = true,
        });
        const heading = try self.candidates.add(&self.catalog, .{
            .key = "generated-heading",
            .props = .{ .text = .{ .content = "Jev chose this component tree" } },
        });
        const input = try self.candidates.add(&self.catalog, .{
            .key = "generated-name",
            .props = .{ .input = .{ .placeholder = "Type a generated value", .state_id = "name" } },
        });
        const row = try self.candidates.add(&self.catalog, .{
            .key = "generated-row",
            .props = .{ .row = .{ .gap = 20 } },
        });
        const checkbox = try self.candidates.add(&self.catalog, .{
            .key = "generated-enabled",
            .props = .{ .checkbox = .{ .label = "Enable generated option", .state_id = "enabled" } },
        });
        const button = try self.candidates.add(&self.catalog, .{
            .key = "generated-action",
            .props = .{ .button = .{ .label = "Run generated action", .action = action } },
        });
        self.status_candidate = try self.candidates.add(&self.catalog, .{
            .key = "generated-status",
            .props = .{ .text = .{ .content = "Bounded action and value queues are ready" } },
        });

        var script = Script{
            .card = card,
            .heading = heading,
            .input = input,
            .row = row,
            .checkbox = checkbox,
            .button = button,
            .status = self.status_candidate,
        };
        try genui.compose(.{ .context = &script, .evaluate_fn = Script.evaluate }, &self.candidates, 1, &self.spec);
        self.initialized = true;
        std.debug.assert(self.spec.node_count == 7);
    }

    fn drainEvents(self: *AppState) void {
        std.debug.assert(self.initialized);
        std.debug.assert(self.status_candidate < self.candidates.count);
        var changed = false;
        while (self.renderer.popEvent()) |_| {
            self.action_count += 1;
            changed = true;
        }
        while (self.renderer.popValueEvent()) |_| {
            self.value_count += 1;
            changed = true;
        }
        if (!changed) return;
        self.updateStatus();
    }

    fn updateStatus(self: *AppState) void {
        std.debug.assert(self.runtime_state.entries[self.enabled_state].value == .boolean);
        std.debug.assert(self.runtime_state.entries[self.name_state].value == .text);
        const name = self.runtime_state.entries[self.name_state].value.text.slice();
        const name_display = name[0..@min(name.len, 96)];
        const status = std.fmt.bufPrint(&self.status_buffer, "Events: {d} action{s}, {d} value update{s} · enabled={s} · name=\"{s}\"", .{
            self.action_count,
            if (self.action_count == 1) "" else "s",
            self.value_count,
            if (self.value_count == 1) "" else "s",
            if (self.runtime_state.entries[self.enabled_state].value.boolean) "true" else "false",
            name_display,
        }) catch unreachable;
        // Initialization fixes the candidate type, and the bounded display name keeps the status within PropText.
        self.candidates.setTextContent(self.status_candidate, status) catch unreachable;
    }

    fn advanceAutoplay(self: *AppState, window: *gooey.Window) void {
        std.debug.assert(self.initialized);
        std.debug.assert(self.autoplay_frame <= 200);
        if (!self.autoplay) return;
        if (self.autoplay_frame == 200) return;
        self.autoplay_frame += 1;
        if (self.autoplay_frame == 40) {
            // Initialization fixes this state slot as text and the literal is within the configured bound.
            self.runtime_state.setText(self.name_state, "Ada Lovelace") catch unreachable;
            self.value_count = 1;
            self.updateStatus();
        }
        if (self.autoplay_frame == 80) {
            self.runtime_state.entries[self.enabled_state].value.boolean = false;
            self.value_count = 2;
            self.updateStatus();
        }
        if (self.autoplay_frame == 120) {
            self.action_count = 1;
            self.updateStatus();
        }
        if (self.autoplay_frame < 200) window.requestRender();
    }
};

const Script = struct {
    card: u8,
    heading: u8,
    input: u8,
    row: u8,
    checkbox: u8,
    button: u8,
    status: u8,
    calls: u8 = 0,

    fn evaluate(pointer: *anyopaque, request: *const core.EvaluationRequest, response: *core.EvaluationResponse) !void {
        const self: *Script = @ptrCast(@alignCast(pointer));
        std.debug.assert(self.card != self.button);
        std.debug.assert(self.heading != self.status);
        self.calls += 1;
        switch (request.*) {
            .selection => {
                var selection = core.Selection{ .root_candidate = self.card };
                selection.selected[self.card] = true;
                selection.selected[self.heading] = true;
                selection.selected[self.input] = true;
                selection.selected[self.row] = true;
                selection.selected[self.checkbox] = true;
                selection.selected[self.button] = true;
                selection.selected[self.status] = true;
                response.* = .{ .selection = selection };
            },
            .layout => {
                var layout = core.Layout{};
                const ordered = [_]u8{ self.heading, self.input, self.row, self.status };
                for (ordered, 0..) |candidate, order| {
                    layout.parent_candidate[candidate] = self.card;
                    layout.order[candidate] = @intCast(order);
                }
                layout.parent_candidate[self.checkbox] = self.row;
                layout.order[self.checkbox] = 0;
                layout.parent_candidate[self.button] = self.row;
                layout.order[self.button] = 1;
                response.* = .{ .layout = layout };
            },
        }
    }
};

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Gooey Gen UI",
    .width = 960,
    .height = 600,
});

pub fn main(init: std.process.Init) !void {
    if (gooey.platform.is_wasm) unreachable;
    try state.initialize();
    state.autoplay = init.environ_map.get("GOOEY_GENUI_AUTOPLAY") != null;
    return App.main(init);
}

fn render(cx: *gooey.Cx) void {
    const app = cx.state(AppState);
    app.drainEvents();
    app.advanceAutoplay(cx.window());
    cx.render(ui.root(.{
        .direction = .column,
        .gap = 20,
        .padding = .{ .all = 44 },
        .background = ui.Color.rgb(0.94, 0.95, 0.98),
    }, .{
        ui.text("Gooey Gen UI", .{ .size = 30, .color = ui.Color.rgb(0.10, 0.14, 0.24) }),
        ui.text("Catalog-constrained composition · Card + Row + Input + Checkbox + Button", .{
            .size = 15,
            .color = ui.Color.rgb(0.34, 0.39, 0.49),
        }),
        GeneratedTree{},
        ui.text("Offline scripted evaluator; production transport targets TypeSafe directly.", .{
            .size = 13,
            .color = ui.Color.rgb(0.45, 0.49, 0.57),
        }),
    }));
}

const GeneratedTree = struct {
    pub fn render(_: GeneratedTree, cx: *gooey.Cx) void {
        const app = cx.state(AppState);
        app.renderer.renderArtifactWithState(cx, &app.artifact, &app.catalog, &app.runtime_state, &app.candidates, &app.spec) catch {
            cx.render(ui.text("Generated tree failed validation", .{ .color = ui.Color.rgb(0.75, 0.12, 0.12) }));
        };
    }
};
