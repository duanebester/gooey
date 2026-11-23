const std = @import("std");
const builtin = @import("builtin");
const id_mod = @import("id.zig");
const input = @import("../input/mod.zig");
const events = @import("events.zig");
const platform_interface = @import("../platform/interface.zig");
const Theme = @import("theme.zig").Theme;
const Live = @import("../accessibility/types.zig").Live;
const Clipboard = @import("clipboard.zig").Clipboard;
const entities = @import("entities.zig");
const retained_mod = @import("retained.zig");
const records = @import("records.zig");
const jobs = @import("jobs.zig");
const ScrollTarget = @import("element.zig").ScrollTarget;

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;

pub fn typeId(comptime T: type) usize {
    return @intFromPtr(@typeName(T).ptr);
}

pub fn typeName(type_id: usize) []const u8 {
    assert(type_id != 0);
    const name: [*:0]const u8 = @ptrFromInt(type_id);
    return std.mem.span(name);
}

pub const Target = struct {
    type_id: usize,
    slot: u32,
    generation: u32,

    pub const slot_root: u32 = std.math.maxInt(u32);

    pub fn isRoot(self: Target) bool {
        return self.slot == slot_root;
    }
};

pub const Handler = struct {
    invoke: *const fn (app: *anyopaque, target: Target, arg: u64, effects: *Effects) void,
    target: Target,
    arg: u64,

    pub fn call(self: Handler, store: *Store, effects: *Effects) void {
        assert(self.target.type_id != 0);
        self.invoke(@ptrCast(store), self.target, self.arg, effects);
    }
};

comptime {
    assert(@sizeOf(Handler) <= 4 * @sizeOf(u64));
}

pub fn Entity(comptime T: type) type {
    return struct {
        slot: u32,
        generation: u32,

        pub const State = T;
    };
}

pub const EntityPool = struct {
    type_id: usize,
    name: []const u8,
    base: [*]u8,
    stride: u32,
    generations: []const u32,
    app_pool: ?*entities.Pool = null,

    pub fn checkedValue(
        self: *const EntityPool,
        slot: u32,
        generation: u32,
        operation: []const u8,
    ) [*]u8 {
        const app_pool = self.app_pool.?;
        if (app_pool.check(slot, generation)) |problem| std.debug.panic(
            "{s}: {t} handle into entity pool '{s}': slot {d} of {d}, " ++
                "generation {d}, slot generation {d}",
            .{
                operation,
                problem,
                self.name,
                slot,
                app_pool.capacity(),
                generation,
                if (slot < app_pool.capacity()) app_pool.generations[slot] else 0,
            },
        );
        return app_pool.valueBytes(slot).ptr;
    }
};

pub const entity_pool_count_max: u32 = 16;

pub const Store = struct {
    root_state: *anyopaque,
    root_type_id: usize,
    pools: []EntityPool,
    pool_count: u32,
    retained: ?*retained_mod.Retained,

    pub fn init(comptime State: type, state: *State, pools: []EntityPool) Store {
        assert(pools.len <= entity_pool_count_max);
        return .{
            .root_state = @ptrCast(state),
            .root_type_id = typeId(State),
            .pools = pools,
            .pool_count = 0,
            .retained = null,
        };
    }

    pub fn registerPool(self: *Store, pool: EntityPool) void {
        assert(self.pool_count < self.pools.len);
        assert(self.findPool(pool.type_id) == null);
        self.pools[self.pool_count] = pool;
        self.pool_count += 1;
    }

    pub fn findPool(self: *const Store, type_id: usize) ?*const EntityPool {
        assert(self.pool_count <= self.pools.len);
        for (self.pools[0..self.pool_count]) |*pool| {
            if (pool.type_id == type_id) return pool;
        }
        return null;
    }

    pub fn appPool(self: *const Store, comptime T: type) *const EntityPool {
        const pool = self.findPool(typeId(T)) orelse std.debug.panic(
            "{s} is not in Config.entities",
            .{@typeName(T)},
        );
        if (pool.app_pool == null) std.debug.panic(
            "{s} is a framework pool, not an entity in Config.entities",
            .{@typeName(T)},
        );
        return pool;
    }

    pub fn freeRemoved(self: *Store) void {
        assert(self.pool_count <= self.pools.len);
        for (self.pools[0..self.pool_count]) |*pool| {
            if (pool.app_pool) |app_pool| app_pool.freeRemoved();
        }
    }

    pub fn resolve(self: *const Store, comptime State: type, target: Target) *State {
        assert(target.type_id == typeId(State));
        if (target.isRoot()) {
            assert(self.root_type_id == typeId(State));
            return @ptrCast(@alignCast(self.root_state));
        }
        const pool = self.findPool(target.type_id) orelse {
            if (comptime !retained_mod.fitsSizeClass(State)) std.debug.panic(
                "handler targets {s}, which is neither an entity nor retained state",
                .{@typeName(State)},
            );
            const handle = Entity(State){ .slot = target.slot, .generation = target.generation };
            return self.retained.?.get(State, handle);
        };
        if (pool.app_pool != null) {
            const value = pool.checkedValue(target.slot, target.generation, "handler");
            return @ptrCast(@alignCast(value));
        }
        assert(target.slot < pool.generations.len);
        assert(pool.generations[target.slot] == target.generation);
        const address = pool.base + @as(usize, target.slot) * pool.stride;
        return @ptrCast(@alignCast(address));
    }
};

pub const FileDialogRequest = struct {
    kind: union(enum) {
        open: PathPromptOptions,
        save: SavePromptOptions,
    },
    on_complete: Handler,
};

pub const PathPromptOptions = platform_interface.PathPromptOptions;
pub const SavePromptOptions = platform_interface.SavePromptOptions;

pub const Effects = struct {
    event: ?*const input.InputEvent,
    completion: ?*const events.Completion,
    render_requested: bool,
    propagation_stopped: bool,
    focus_request: FocusRequest,
    quit_requested: bool,
    file_dialog: ?FileDialogRequest,
    font_request: ?FontRequest,
    theme_request: ?*const Theme,
    announcement: ?Announcement,
    click_request: ?ElementId,
    clipboard: ?*Clipboard,
    store: ?*Store,
    current: ElementId,
    pointer_drag: ?PointerDrag,
    rendered: ?*const records.Frame,
    focused_id: ElementId,
    drop: ?Drop,
    drag_start: ?DragStart,
    gesture_idle: bool,
    jobs: ?*jobs.Pool,
    job: ?jobs.Delivery,
    scroll_request: ?ScrollRequest,
    dialogs: ?DialogView,

    pub const JobId = jobs.JobId;
    pub const JobHandlers = jobs.Handlers;
    pub const JobDone = jobs.Done;
    pub const JobOutcome = jobs.Outcome;
    pub const SpawnError = jobs.SpawnError;
    pub const ScrollRequest = struct { id: ElementId, target: ScrollTarget };

    pub const Drop = struct { type_id: usize, payload: u64 };

    pub const DialogView = struct {
        pending: *const ?FileDialogRequest,
        slots: []const ?Handler,

        fn busy(self: *const DialogView) bool {
            assert(self.slots.len > 0);
            if (self.pending.* != null) return true;
            for (self.slots) |slot| {
                if (slot == null) return false;
            }
            return true;
        }
    };

    pub const DialogError = error{DialogBusy};

    pub const DragStart = struct { id: ElementId, started: bool };

    pub const PointerDrag = struct {
        phase: Phase,
        x: f32,
        y: f32,
        start_x: f32,
        start_y: f32,
        button: input.MouseButton,
        modifiers: input.Modifiers,

        pub const Phase = enum { begin, move, end, cancel };
    };

    pub const FocusRequest = union(enum) { none, focus: ElementId, blur };

    pub const FontRequest = struct { name: []const u8, size: f32 };

    pub const Announcement = struct { text: []const u8, politeness: Live };

    pub fn init(event: ?*const input.InputEvent, current: ElementId) Effects {
        return .{
            .event = event,
            .completion = null,
            .render_requested = false,
            .propagation_stopped = false,
            .focus_request = .none,
            .quit_requested = false,
            .file_dialog = null,
            .font_request = null,
            .theme_request = null,
            .announcement = null,
            .click_request = null,
            .clipboard = null,
            .store = null,
            .current = current,
            .pointer_drag = null,
            .rendered = null,
            .focused_id = .root,
            .drop = null,
            .drag_start = null,
            .gesture_idle = false,
            .jobs = null,
            .job = null,
            .scroll_request = null,
            .dialogs = null,
        };
    }

    pub fn inputEvent(self: *const Effects) ?*const input.InputEvent {
        return self.event;
    }

    pub fn focusedElement(self: *const Effects) ?ElementId {
        if (self.focused_id == .root) return null;
        assert(self.focused_id.isKeyed());
        return self.focused_id;
    }

    pub fn dropPayload(self: *const Effects, comptime T: type) ?T {
        const dropped = self.drop orelse return null;
        assert(dropped.type_id != 0);
        if (dropped.type_id != typeId(T)) return null;
        return unpackArg(T, dropped.payload);
    }

    pub fn pointerDrag(self: *const Effects) ?PointerDrag {
        const drag = self.pointer_drag orelse return null;
        assert(std.math.isFinite(drag.x));
        assert(std.math.isFinite(drag.start_x));
        return drag;
    }

    pub fn bounds(self: *const Effects, id: ElementId) ?records.Rect {
        assert(id.isKeyed());
        const frame = self.rendered orelse return null;
        assert(frame.hit_count <= frame.hits.len);
        for (frame.hits[0..frame.hit_count]) |*record| {
            if (record.id == id) return record.bounds;
        }
        return null;
    }

    pub fn startDrag(self: *Effects, id: ElementId) bool {
        assert(id.isKeyed());
        assert(self.drag_start == null);
        const started = self.dragStarts(id);
        self.drag_start = .{ .id = id, .started = started };
        if (started) assert(self.gesture_idle);
        return started;
    }

    fn dragStarts(self: *const Effects, id: ElementId) bool {
        const frame = self.rendered orelse return false;
        assert(frame.hit_count <= frame.hits.len);
        for (frame.hits[0..frame.hit_count]) |*record| {
            if (record.id != id) continue;
            if (record.drag_type == 0) {
                std.debug.panic("effects.startDrag: element {x} has no Box.draggable", .{
                    @backingInt(id),
                });
            }
            return self.gesture_idle;
        }
        return false;
    }

    pub fn spawn(
        self: *Effects,
        comptime Job: type,
        job_input: *const Job.Input,
        handlers: JobHandlers,
    ) SpawnError!JobId {
        comptime jobs.checkSpec(Job);
        assert(handlers.on_done.target.isRoot());
        if (handlers.on_result) |on_result| assert(on_result.target.isRoot());
        const pool = self.jobs orelse std.debug.panic("effects.spawn({s}) outside a handler " ++
            "or on_init", .{@typeName(Job)});
        return pool.spawn(
            typeId(Job),
            jobs.erasedRun(Job),
            Job.posts_max,
            std.mem.asBytes(job_input),
            handlers,
        );
    }

    pub fn cancelJob(self: *Effects, id: JobId) void {
        const pool = self.jobs orelse std.debug.panic("effects.cancelJob outside a handler", .{});
        pool.cancel(id);
    }

    pub fn jobResult(self: *const Effects, comptime Job: type) ?*const Job.Result {
        comptime jobs.checkSpec(Job);
        const delivery = self.job orelse return null;
        if (delivery.type_id != typeId(Job)) return null;
        const bytes = delivery.result orelse return null;
        return @ptrCast(bytes);
    }

    pub fn jobDone(self: *const Effects) ?JobDone {
        const delivery = self.job orelse return null;
        const done = delivery.done orelse return null;
        assert(done.id.slot == delivery.id.slot);
        return done;
    }

    pub fn jobId(self: *const Effects) ?JobId {
        const delivery = self.job orelse return null;
        return delivery.id;
    }

    pub fn scrollTo(self: *Effects, id: ElementId, target: ScrollTarget) void {
        assert(id.isKeyed());
        assert(self.scroll_request == null);
        switch (target) {
            .offset => |offset| {
                assert(std.math.isFinite(offset.x));
                assert(std.math.isFinite(offset.y));
            },
            else => {},
        }
        self.scroll_request = .{ .id = id, .target = target };
    }

    pub fn completionEvent(self: *const Effects) ?*const events.Completion {
        return self.completion;
    }

    pub fn requestRender(self: *Effects) void {
        self.render_requested = true;
    }

    pub fn stopPropagation(self: *Effects) void {
        self.propagation_stopped = true;
    }

    pub fn focus(self: *Effects, id: ElementId) void {
        assert(id.isKeyed());
        self.focus_request = .{ .focus = id };
    }

    pub fn blur(self: *Effects) void {
        self.focus_request = .blur;
    }

    pub fn click(self: *Effects, id: ElementId) void {
        assert(id.isKeyed());
        assert(self.click_request == null);
        self.click_request = id;
    }

    pub fn quit(self: *Effects) void {
        self.quit_requested = true;
    }

    pub fn openFileDialog(self: *Effects, request: FileDialogRequest) DialogError!void {
        assert(self.file_dialog == null);
        const view = self.dialogs orelse std.debug.panic(
            "effects.openFileDialog outside a routed handler; on_init opens no dialog",
            .{},
        );
        switch (request.kind) {
            .open => |options| assert(options.files or options.directories),
            .save => |options| {
                if (options.directory) |directory| assert(directory.len > 0);
                if (options.suggested_name) |name| assert(name.len > 0);
            },
        }
        if (view.busy()) return error.DialogBusy;
        self.file_dialog = request;
        assert(view.pending.* == null);
    }

    pub fn setFont(self: *Effects, name: []const u8, size: f32) void {
        assert(name.len > 0);
        assert(size > 0 and size < 1000);
        self.font_request = .{ .name = name, .size = size };
    }

    pub fn setTheme(self: *Effects, theme: *const Theme) void {
        self.theme_request = theme;
        assert(self.theme_request.? == theme);
    }

    pub fn announce(self: *Effects, text: []const u8, politeness: Live) void {
        assert(text.len > 0);
        assert(politeness != .off);
        assert(self.announcement == null);
        self.announcement = .{ .text = text, .politeness = politeness };
    }

    pub fn create(self: *Effects, comptime T: type, value: T) Entity(T) {
        comptime assert(@typeInfo(T) == .@"struct");
        const pool = self.store.?.appPool(T);
        const app_pool = pool.app_pool.?;
        const slot = app_pool.claim() orelse std.debug.panic(
            "effects.create: entity pool '{s}' exhausted: capacity {d}, requested 1",
            .{ pool.name, app_pool.capacity() },
        );
        const handle = Entity(T){ .slot = slot, .generation = app_pool.generations[slot] };
        const target: *T = @ptrCast(@alignCast(pool.checkedValue(
            handle.slot,
            handle.generation,
            "effects.create",
        )));
        target.* = value;
        return handle;
    }

    pub fn remove(self: *Effects, comptime T: type, handle: Entity(T)) void {
        const pool = self.store.?.appPool(T);
        _ = pool.checkedValue(handle.slot, handle.generation, "effects.remove");
        if (!pool.app_pool.?.markRemoved(handle.slot)) std.debug.panic(
            "effects.remove: entity pool '{s}' slot {d} removed twice in one drain",
            .{ pool.name, handle.slot },
        );
    }

    pub fn handler(_: *const Effects, comptime method: anytype) Handler {
        const built = bind(method, .{});
        assert(built.target.isRoot());
        return built;
    }
};

pub const Shape = struct {
    name: []const u8,
    State: type,
    Arg: type,
    takes_effects: bool,
};

const shapes_help =
    "a handler method has one of these shapes: fn(*State) void, " ++
    "fn(*State, Arg) void, fn(*State, *Effects) void, fn(*State, Arg, *Effects) void";

pub fn shapeOf(comptime method: anytype) Shape {
    const Method = @TypeOf(method);
    if (@typeInfo(Method) != .@"fn") {
        @compileError("cx.on expects a method such as State.increment, found " ++
            @typeName(Method));
    }
    const params = @typeInfo(Method).@"fn".param_types;
    const label = "cx.on(" ++ @typeName(Method) ++ "): ";
    if (@typeInfo(Method).@"fn".return_type != void) @compileError(label ++ shapes_help);
    if (params.len < 1 or params.len > 3) @compileError(label ++ shapes_help);
    for (params) |param| {
        if (param == null) @compileError(label ++ "parameters cannot be anytype");
    }
    const State = stateOf(params[0].?, label);
    const name = @typeName(State) ++ "." ++ methodLabel(method);
    if (params.len == 1) {
        return .{ .name = name, .State = State, .Arg = void, .takes_effects = false };
    }
    if (params.len == 2) {
        if (params[1].? == *Effects) {
            return .{ .name = name, .State = State, .Arg = void, .takes_effects = true };
        }
        checkArgType(params[1].?, label);
        return .{ .name = name, .State = State, .Arg = params[1].?, .takes_effects = false };
    }
    if (params[2].? != *Effects) @compileError(label ++ shapes_help);
    checkArgType(params[1].?, label);
    return .{ .name = name, .State = State, .Arg = params[1].?, .takes_effects = true };
}

fn methodLabel(comptime method: anytype) []const u8 {
    comptime {
        const rendered = @typeName(NameProbe(method));
        const prefix = "(function '";
        const start = std.mem.indexOf(u8, rendered, prefix) orelse
            return @typeName(@TypeOf(method));
        const tail = rendered[start + prefix.len ..];
        const end = std.mem.indexOfScalar(u8, tail, '\'') orelse
            return @typeName(@TypeOf(method));
        return tail[0..end];
    }
}

fn NameProbe(comptime method: anytype) type {
    return struct {
        comptime {
            _ = method;
        }
    };
}

fn stateOf(comptime First: type, comptime label: []const u8) type {
    const info = @typeInfo(First);
    if (info != .pointer or info.pointer.size != .one or info.pointer.attrs.@"const") {
        @compileError(label ++ "the first parameter must be *State, found " ++
            @typeName(First));
    }
    if (info.pointer.child == Effects) {
        @compileError(label ++ "the first parameter must be *State, not *Effects");
    }
    return info.pointer.child;
}

fn checkArgType(comptime Arg: type, comptime label: []const u8) void {
    if (@sizeOf(Arg) > @sizeOf(u64)) {
        @compileError(label ++ "the argument type " ++ @typeName(Arg) ++
            " is larger than 8 bytes; pass an index instead");
    }
}

pub fn checkOptions(comptime Options: type, comptime shape: Shape) void {
    const label = "cx.on(" ++ shape.name ++ "): ";
    if (@typeInfo(Options) != .@"struct") {
        @compileError(label ++ "options must be a struct literal such as .{}");
    }
    for (@typeInfo(Options).@"struct".field_names) |field| {
        const known = std.mem.eql(u8, field, "arg") or std.mem.eql(u8, field, "entity");
        if (!known) {
            @compileError(label ++ "unknown option ." ++ field ++
                "; cx.on accepts only .arg and .entity");
        }
    }
    if (@hasField(Options, "arg") and shape.Arg == void) {
        @compileError(label ++ "the method takes no argument; remove .arg");
    }
    if (!@hasField(Options, "arg") and shape.Arg != void) {
        @compileError(label ++ "the method takes " ++ @typeName(shape.Arg) ++ "; pass .arg");
    }
    if (@hasField(Options, "entity")) {
        if (@FieldType(Options, "entity") != Entity(shape.State)) {
            @compileError(label ++ ".entity must be Entity(" ++ @typeName(shape.State) ++ ")");
        }
    }
}

pub fn bind(comptime method: anytype, options: anytype) Handler {
    const shape = comptime shapeOf(method);
    const Options = @TypeOf(options);
    comptime checkOptions(Options, shape);
    var target = Target{
        .type_id = typeId(shape.State),
        .slot = Target.slot_root,
        .generation = 0,
    };
    if (@hasField(Options, "entity")) {
        target.slot = options.entity.slot;
        target.generation = options.entity.generation;
    }
    var arg: u64 = 0;
    if (@hasField(Options, "arg")) {
        const value: shape.Arg = options.arg;
        arg = packArg(shape.Arg, value);
    }
    const handler = Handler{
        .invoke = Invoker(method, shape).invoke,
        .target = target,
        .arg = arg,
    };
    assert(handler.target.type_id != 0);
    return handler;
}

fn Invoker(comptime method: anytype, comptime shape: Shape) type {
    return struct {
        fn invoke(app: *anyopaque, target: Target, arg: u64, effects: *Effects) void {
            const store: *Store = @ptrCast(@alignCast(app));
            const state = store.resolve(shape.State, target);
            if (shape.Arg == void) {
                assert(arg == 0);
                if (shape.takes_effects) method(state, effects) else method(state);
            } else {
                const value = unpackArg(shape.Arg, arg);
                if (shape.takes_effects) method(state, value, effects) else method(state, value);
            }
            effects.requestRender();
        }
    };
}

pub fn packArg(comptime Arg: type, arg: Arg) u64 {
    comptime assert(@sizeOf(Arg) <= @sizeOf(u64));
    var storage: u64 = 0;
    @memcpy(std.mem.asBytes(&storage)[0..@sizeOf(Arg)], std.mem.asBytes(&arg));
    return storage;
}

pub fn unpackArg(comptime Arg: type, storage: u64) Arg {
    comptime assert(@sizeOf(Arg) <= @sizeOf(u64));
    var result: Arg = undefined;
    @memcpy(std.mem.asBytes(&result), std.mem.asBytes(&storage)[0..@sizeOf(Arg)]);
    return result;
}

test "bind detects every method shape and passes arg and effects" {
    const State = struct {
        total: i64 = 0,
        effects_seen: u32 = 0,
        fn bump(self: *@This()) void {
            self.total += 1;
        }
        fn add(self: *@This(), amount: i32) void {
            self.total += amount;
        }
        fn note(self: *@This(), effects: *Effects) void {
            self.effects_seen += 1;
            effects.blur();
        }
        fn addNote(self: *@This(), amount: i8, effects: *Effects) void {
            self.total += amount;
            effects.stopPropagation();
        }
    };
    var state = State{};
    var store = Store.init(State, &state, &.{});
    var effects = Effects.init(null, .root);
    bind(State.bump, .{}).call(&store, &effects);
    bind(State.add, .{ .arg = -5 }).call(&store, &effects);
    bind(State.note, .{}).call(&store, &effects);
    bind(State.addNote, .{ .arg = 100 }).call(&store, &effects);
    try std.testing.expectEqual(@as(i64, 96), state.total);
    try std.testing.expectEqual(@as(u32, 1), state.effects_seen);
    try std.testing.expect(effects.render_requested);
    try std.testing.expect(effects.propagation_stopped);
    try std.testing.expectEqual(Effects.FocusRequest.blur, effects.focus_request);
}
