//! Focus Timer - Pomodoro productivity app (Cx API)
//!
//! Demonstrates:
//! - Custom animated shader (plasma effect)
//! - Text decorations (strikethrough for completed tasks)
//! - Component system (Button, Checkbox, TextInput)
//! - Unified Cx context with cx.update() / cx.command()
//! - Timer state management
//! - Beautiful, practical UI

const std = @import("std");
const gooey = @import("gooey");

// Use platform abstraction for time
const platform = gooey.platform;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const Checkbox = gooey.Checkbox;
const TextInput = gooey.TextInput;

const custom_shader = gooey.platform.mac.metal.custom_shader;

/// Colorful flowing plasma effect
pub const plasma_shader =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float4 scene = iChannel0.sample(iChannel0Sampler, uv);
    \\    float time = uniforms.iTime * 0.5;
    \\
    \\    // Plasma calculation
    \\    float2 p = uv * 4.0 - 2.0;
    \\
    \\    float v1 = sin(p.x + time);
    \\    float v2 = sin(p.y + time);
    \\    float v3 = sin(p.x + p.y + time);
    \\    float v4 = sin(length(p) + time * 1.5);
    \\
    \\    float v = v1 + v2 + v3 + v4;
    \\    v = v * 0.5 + 0.5;
    \\
    \\    // Color palette - cycle through vibrant colors
    \\    float3 plasma;
    \\    plasma.r = sin(v * 3.14159 + time) * 0.5 + 0.5;
    \\    plasma.g = sin(v * 3.14159 + time + 2.094) * 0.5 + 0.5;
    \\    plasma.b = sin(v * 3.14159 + time + 4.188) * 0.5 + 0.5;
    \\
    \\    // Make it more vibrant
    \\    plasma = pow(plasma, float3(0.8));
    \\
    \\    // Edge mask - stronger effect at edges
    \\    float2 center = abs(uv - 0.5) * 2.0;
    \\    float edge = max(center.x, center.y);
    \\    edge = smoothstep(0.3, 1.0, edge);
    \\
    \\    // Blend: plasma at edges, scene in center
    \\    float sceneBrightness = dot(scene.rgb, float3(0.299, 0.587, 0.114));
    \\    float3 final = mix(scene.rgb, plasma, edge * 0.7 * (1.0 - sceneBrightness * 0.5));
    \\
    \\    fragColor = float4(final, 1.0);
    \\}
;

// =============================================================================
// Models
// =============================================================================

const Task = struct {
    text: []const u8,
    completed: bool = false,
};

const TimerPhase = enum {
    idle,
    focus,
    short_break,
    long_break,

    fn duration(self: TimerPhase) u32 {
        return switch (self) {
            .idle => 0,
            .focus => 25 * 60,
            .short_break => 5 * 60,
            .long_break => 15 * 60,
        };
    }

    fn label(self: TimerPhase) []const u8 {
        return switch (self) {
            .idle => "Ready",
            .focus => "Focus Time",
            .short_break => "Short Break",
            .long_break => "Long Break",
        };
    }

    fn color(self: TimerPhase) ui.Color {
        return switch (self) {
            .idle => ui.Color.rgb(0.5, 0.5, 0.5),
            .focus => ui.Color.rgb(0.9, 0.3, 0.3),
            .short_break => ui.Color.rgb(0.3, 0.8, 0.5),
            .long_break => ui.Color.rgb(0.3, 0.5, 0.9),
        };
    }
};

// =============================================================================
// Application State
// =============================================================================

const MaxTasks = 20;

const AppState = struct {
    // Timer state
    phase: TimerPhase = .idle,
    time_remaining: u32 = 0,
    sessions_completed: u32 = 0,
    is_running: bool = false,

    // Tasks
    tasks: [MaxTasks]gooey.Entity(Task) = [_]gooey.Entity(Task){gooey.Entity(Task).nil()} ** MaxTasks,
    task_count: usize = 0,
    input_text: []const u8 = "",

    // Last tick time for timer updates
    last_tick: i64 = 0,

    // =========================================================================
    // Pure state methods - use with cx.update()
    // =========================================================================

    pub fn startFocus(self: *AppState) void {
        self.phase = .focus;
        self.time_remaining = TimerPhase.focus.duration();
        self.is_running = true;
        self.last_tick = getTimestamp();
    }

    pub fn startBreak(self: *AppState) void {
        self.phase = if (self.sessions_completed % 4 == 3) .long_break else .short_break;
        self.time_remaining = self.phase.duration();
        self.is_running = true;
        self.last_tick = getTimestamp();
    }

    pub fn reset(self: *AppState) void {
        self.phase = .idle;
        self.time_remaining = 0;
        self.is_running = false;
    }

    pub fn pause(self: *AppState) void {
        self.is_running = false;
    }

    pub fn resumeTimer(self: *AppState) void {
        self.is_running = true;
        self.last_tick = getTimestamp();
    }

    pub fn tick(self: *AppState) void {
        if (!self.is_running or self.phase == .idle) return;

        const now = getTimestamp();
        const elapsed = now - self.last_tick;

        if (elapsed >= 1000) {
            self.last_tick = now;
            if (self.time_remaining > 0) {
                self.time_remaining -= 1;
            } else {
                if (self.phase == .focus) {
                    self.sessions_completed += 1;
                }
                self.is_running = false;
            }
        }
    }

    // =========================================================================
    // Command methods - use with cx.command() (need Gooey access)
    // =========================================================================

    pub fn addTask(self: *AppState, g: *gooey.Gooey) void {
        if (self.input_text.len == 0) return;
        if (self.task_count >= MaxTasks) return;

        const text_copy = g.allocator.dupe(u8, self.input_text) catch return;
        const task = g.createEntity(Task, .{ .text = text_copy }) catch return;

        self.tasks[self.task_count] = task;
        self.task_count += 1;

        if (g.textInput("task-input")) |input| {
            input.clear();
        }
        self.input_text = "";
    }

    pub fn toggleTask(self: *AppState, g: *gooey.Gooey, task_index: usize) void {
        if (task_index >= self.task_count) return;

        const entity = self.tasks[task_index];
        if (g.writeEntity(Task, entity)) |task| {
            task.completed = !task.completed;
        }
    }

    pub fn clearCompleted(self: *AppState, g: *gooey.Gooey) void {
        var write_idx: usize = 0;
        for (0..self.task_count) |read_idx| {
            const entity = self.tasks[read_idx];
            if (g.readEntity(Task, entity)) |task| {
                if (task.completed) {
                    g.allocator.free(task.text);
                    g.getEntities().remove(entity.id);
                    continue;
                }
            }
            self.tasks[write_idx] = entity;
            write_idx += 1;
        }
        self.task_count = write_idx;
    }

    // =========================================================================
    // Helper methods (no context needed)
    // =========================================================================

    fn tasksSlice(self: *const AppState) []const gooey.Entity(Task) {
        return self.tasks[0..self.task_count];
    }

    fn completedCount(self: *const AppState, g: *gooey.Gooey) usize {
        var count: usize = 0;
        for (self.tasksSlice()) |entity| {
            if (g.readEntity(Task, entity)) |task| {
                if (task.completed) count += 1;
            }
        }
        return count;
    }
};

// =============================================================================
// Components - Now receive *Cx directly!
// =============================================================================

const TimerDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        const minutes = s.time_remaining / 60;
        const seconds = s.time_remaining % 60;

        var time_buf: [8]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds }) catch "00:00";

        cx.box(.{
            .padding = .{ .all = 32 },
            .background = ui.Color.rgba(1, 1, 1, 0.9),
            .corner_radius = 24,
            .alignment = .{ .main = .center, .cross = .center },
            .direction = .column,
            .gap = 8,
            .shadow = .{ .blur_radius = 20, .color = ui.Color.rgba(0, 0, 0, 0.1) },
        }, .{
            ui.text(s.phase.label(), .{
                .size = 18,
                .color = s.phase.color(),
                .underline = s.is_running,
            }),
            ui.text(time_str, .{ .size = 72, .color = ui.Color.rgb(0.1, 0.1, 0.1) }),
            ui.textFmt("Sessions: {}", .{s.sessions_completed}, .{
                .size = 14,
                .color = ui.Color.rgb(0.6, 0.6, 0.6),
            }),
        });
    }
};

const TimerControls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.hstack(.{ .gap = 12, .alignment = .center }, .{
            ControlButtons{},
            ResetButton{},
        });
    }
};

const ResetButton = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        if (s.phase != .idle) {
            cx.box(.{}, .{
                Button{ .label = "Reset", .variant = .secondary, .on_click_handler = cx.update(AppState, AppState.reset) },
            });
        }
    }
};

const ControlButtons = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        switch (s.phase) {
            .idle => {
                cx.box(.{}, .{
                    Button{ .label = "Start Focus", .on_click_handler = cx.update(AppState, AppState.startFocus) },
                });
            },
            .focus, .short_break, .long_break => {
                if (s.time_remaining == 0) {
                    if (s.phase == .focus) {
                        cx.box(.{}, .{
                            Button{ .label = "Take Break", .variant = .secondary, .on_click_handler = cx.update(AppState, AppState.startBreak) },
                        });
                    } else {
                        cx.box(.{}, .{
                            Button{ .label = "Start Focus", .on_click_handler = cx.update(AppState, AppState.startFocus) },
                        });
                    }
                } else if (s.is_running) {
                    cx.box(.{}, .{
                        Button{ .label = "Pause", .variant = .danger, .on_click_handler = cx.update(AppState, AppState.pause) },
                    });
                } else {
                    cx.box(.{}, .{
                        Button{ .label = "Resume", .on_click_handler = cx.update(AppState, AppState.resumeTimer) },
                    });
                }
            },
        }
    }
};

const TaskInput = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.hstack(.{ .gap = 12, .alignment = .center }, .{
            TextInput{
                .id = "task-input",
                .placeholder = "Add a task...",
                .width = 250,
                .bind = &s.input_text,
                // Soft, modern styling
                .background = ui.Color.rgba(1.0, 1.0, 1.0, 0.9),
                .border_color = ui.Color.rgba(0.0, 0.0, 0.0, 0.1),
                .border_color_focused = ui.Color.rgb(0.4, 0.6, 1.0),
                .text_color = ui.Color.rgb(0.2, 0.2, 0.2),
                .placeholder_color = ui.Color.rgb(0.5, 0.5, 0.5),
                .corner_radius = 8,
            },
            Button{ .label = "Add", .on_click_handler = cx.command(AppState, AppState.addTask) },
        });
    }
};

const TaskItem = struct {
    task: gooey.Entity(Task),
    index: usize,

    pub fn render(self: @This(), cx: *Cx) void {
        const g = cx.getGooey();
        const data = g.readEntity(Task, self.task) orelse return;

        var id_buf: [32]u8 = undefined;
        const checkbox_id = std.fmt.bufPrint(&id_buf, "task-{}", .{self.task.id.id}) catch "task";

        const text_color = if (data.completed)
            ui.Color.rgb(0.6, 0.6, 0.6)
        else
            ui.Color.rgb(0.2, 0.2, 0.2);

        cx.hstack(.{ .gap = 12, .alignment = .center }, .{
            Checkbox{
                .id = checkbox_id,
                .checked = data.completed,
                .on_click_handler = cx.commandWith(AppState, self.index, AppState.toggleTask),
                .checked_background = ui.Color.rgb(0.3, 0.8, 0.5),
            },
            ui.text(data.text, .{
                .size = 16,
                .color = text_color,
                .strikethrough = data.completed,
            }),
        });
    }
};

const TaskList = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .padding = .{ .all = 16 },
            .background = ui.Color.rgba(1, 1, 1, 0.8),
            .corner_radius = 12,
            .direction = .column,
            .gap = 8,
            .min_height = 150,
            .min_width = 320,
        }, .{
            cx.hstack(.{ .gap = 8, .alignment = .center }, .{
                ui.text("Tasks", .{ .size = 16, .color = ui.Color.rgb(0.3, 0.3, 0.3) }),
                ui.spacer(),
                ClearDoneButton{},
            }),
            TaskItems{},
        });
    }
};

const ClearDoneButton = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);
        const g = cx.getGooey();

        if (s.completedCount(g) > 0) {
            cx.box(.{}, .{
                Button{ .label = "Clear done", .size = .small, .variant = .secondary, .on_click_handler = cx.command(AppState, AppState.clearCompleted) },
            });
        }
    }
};

const TaskItems = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        for (s.tasksSlice(), 0..) |entity, index| {
            cx.box(.{ .padding = .{ .symmetric = .{ .x = 0, .y = 4 } } }, .{
                TaskItem{ .task = entity, .index = index },
            });
        }

        if (s.task_count == 0) {
            cx.box(.{}, .{
                ui.text("No tasks yet", .{ .size = 14, .color = ui.Color.rgb(0.6, 0.6, 0.6) }),
            });
        }
    }
};

// =============================================================================
// Entry Point
// =============================================================================

var app_state = AppState{};

const App = gooey.App(AppState, &app_state, render, .{
    .title = "Focus Timer",
    .width = 500,
    .height = 700,
    .custom_shaders = &.{plasma_shader},
});

// Force type analysis - triggers @export on WASM
comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

fn render(cx: *Cx) void {
    const s = cx.state(AppState);

    // Tick the timer
    s.tick();

    const size = cx.windowSize();

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.12, 0.12, 0.15),
        .padding = .{ .all = 32 },
        .gap = 24,
        .direction = .column,
        .alignment = .{ .cross = .center },
    }, .{
        ui.text("Focus Timer", .{
            .size = 28,
            .color = ui.Color.rgb(0.9, 0.9, 0.95),
            .underline = true,
        }),
        TimerDisplay{},
        TimerControls{},
        TaskInput{},
        TaskList{},
    });
}

fn getTimestamp() i64 {
    return platform.time.milliTimestamp();
}
