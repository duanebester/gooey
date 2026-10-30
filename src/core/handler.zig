//! Handler and Effects (contract §4).
//!
//! A handler is a type-erased method call: `invoke` is generated per method
//! by `bind`, `target` names the state it runs on (the app's root state or an
//! entity), and `arg` is the method's argument packed into 8 bytes. The router
//! invokes handlers from the drain phase on the main thread, so the number of
//! calls per tick is bounded by the number of drained events.
//!
//! `Effects` is the narrow command context a handler may use. It records
//! requests (focus, blur, render, file dialog, quit) that the tick applies
//! after the handler returns; it never exposes window internals.

const std = @import("std");
const builtin = @import("builtin");
const id_mod = @import("id.zig");
const input = @import("../input/mod.zig");
const events = @import("events.zig");

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;

/// A type's identity at runtime: the address of its name. Stable for the
/// program's lifetime and unique per type.
pub fn typeId(comptime T: type) usize {
    return @intFromPtr(@typeName(T).ptr);
}

/// The name behind a `typeId`, for safety messages.
pub fn typeName(type_id: usize) []const u8 {
    assert(type_id != 0);
    const name: [*:0]const u8 = @ptrFromInt(type_id);
    return std.mem.span(name);
}

pub const Target = struct {
    /// `typeId` of the state the method takes.
    type_id: usize,
    /// `slot_root` selects the root state; anything else is an entity slot.
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

    /// Run the handler against `store`. Called by the router only.
    pub fn call(self: Handler, store: *Store, effects: *Effects) void {
        assert(self.target.type_id != 0);
        self.invoke(@ptrCast(store), self.target, self.arg, effects);
    }
};

comptime {
    // Three words plus the target's type id: handlers are copied into every
    // frame's handler table, so their size is part of the records budget.
    assert(@sizeOf(Handler) <= 4 * @sizeOf(u64));
}

/// A typed handle into an entity pool. Generation-checked on every access.
pub fn Entity(comptime T: type) type {
    return struct {
        slot: u32,
        generation: u32,

        pub const State = T;
    };
}

/// One fixed pool of entities of one type, registered with the store.
pub const EntityPool = struct {
    type_id: usize,
    name: []const u8,
    base: [*]u8,
    stride: u32,
    generations: []const u32,
};

/// Most entity pools one store holds: the framework's text-engine pools plus
/// the app's `config.entities`.
pub const entity_pool_count_max: u32 = 16;

/// What a handler's `app` pointer points at: the root state and the entity
/// pools, without the app's generic type.
pub const Store = struct {
    root_state: *anyopaque,
    root_type_id: usize,
    pools: [entity_pool_count_max]EntityPool,
    pool_count: u32,

    pub fn init(comptime State: type, state: *State) Store {
        return .{
            .root_state = @ptrCast(state),
            .root_type_id = typeId(State),
            .pools = undefined,
            .pool_count = 0,
        };
    }

    pub fn registerPool(self: *Store, pool: EntityPool) void {
        assert(self.pool_count < entity_pool_count_max);
        assert(self.findPool(pool.type_id) == null);
        self.pools[self.pool_count] = pool;
        self.pool_count += 1;
    }

    pub fn findPool(self: *const Store, type_id: usize) ?*const EntityPool {
        assert(self.pool_count <= entity_pool_count_max);
        for (self.pools[0..self.pool_count]) |*pool| {
            if (pool.type_id == type_id) return pool;
        }
        return null;
    }

    /// The state a target names. A stale generation or wrong type is a
    /// programmer error: handlers are rebuilt every frame from live state.
    pub fn resolve(self: *const Store, comptime State: type, target: Target) *State {
        assert(target.type_id == typeId(State));
        if (target.isRoot()) {
            assert(self.root_type_id == typeId(State));
            return @ptrCast(@alignCast(self.root_state));
        }
        const pool = self.findPool(target.type_id) orelse std.debug.panic(
            "handler targets {s}, which is not a registered entity type",
            .{@typeName(State)},
        );
        assert(target.slot < pool.generations.len);
        assert(pool.generations[target.slot] == target.generation);
        const address = pool.base + @as(usize, target.slot) * pool.stride;
        return @ptrCast(@alignCast(address));
    }
};

/// File dialog requests a handler can make (contract §4, rule 5). The result
/// arrives as a completion event with an explicit outcome.
pub const FileDialogRequest = struct {
    kind: enum { open, save },
    /// Invoked with the completion (`Effects.completionEvent`).
    on_complete: Handler,
};

/// Requests a handler makes. The tick applies them after the handler returns.
pub const Effects = struct {
    event: ?*const input.InputEvent,
    completion: ?*const events.Completion,
    render_requested: bool,
    propagation_stopped: bool,
    focus_request: FocusRequest,
    quit_requested: bool,
    file_dialog: ?FileDialogRequest,
    font_request: ?FontRequest,
    /// The element the router is delivering to, for `focusSelf`.
    current: ElementId,

    pub const FocusRequest = union(enum) { none, focus: ElementId, blur };

    /// A font change: the family name is copied when the handler returns.
    pub const FontRequest = struct { name: []const u8, size: f32 };

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
            .current = current,
        };
    }

    /// The input event being delivered, for key and text handlers.
    pub fn inputEvent(self: *const Effects) ?*const input.InputEvent {
        return self.event;
    }

    /// The completion being delivered, for `FileDialogRequest.on_complete`.
    pub fn completionEvent(self: *const Effects) ?*const events.Completion {
        return self.completion;
    }

    pub fn requestRender(self: *Effects) void {
        self.render_requested = true;
    }

    pub fn stopPropagation(self: *Effects) void {
        self.propagation_stopped = true;
    }

    /// Focus a keyed element. Applied after the handler returns.
    pub fn focus(self: *Effects, id: ElementId) void {
        assert(id.isKeyed());
        self.focus_request = .{ .focus = id };
    }

    pub fn blur(self: *Effects) void {
        self.focus_request = .blur;
    }

    pub fn quit(self: *Effects) void {
        self.quit_requested = true;
    }

    /// Ask for a file dialog. The tick opens it on the main thread after the
    /// drain, so it never runs inside the router; at most one per handler.
    pub fn openFileDialog(self: *Effects, request: FileDialogRequest) void {
        assert(self.file_dialog == null);
        self.file_dialog = request;
    }

    /// Replace the app family (`Config.font`) with `name` at `size` points
    /// (decision 8). The tick reloads it after the drain, once no frame is in
    /// flight, into the same face slots, so it claims no storage. A family
    /// that fails to load is logged and the previous one stays.
    pub fn setFont(self: *Effects, name: []const u8, size: f32) void {
        assert(name.len > 0);
        assert(size > 0 and size < 1000);
        self.font_request = .{ .name = name, .size = size };
    }

    /// A handler for `method` on the root state, for a request's completion
    /// (`.on_complete = effects.handler(State.onPicked)`), so completion
    /// handlers need not be built during render (decision 7). The router
    /// checks the state type when the request is applied.
    pub fn handler(_: *const Effects, comptime method: anytype) Handler {
        const built = bind(method, .{});
        assert(built.target.isRoot());
        return built;
    }
};

// =============================================================================
// Building handlers
// =============================================================================

/// What `bind` learned from a method's signature.
pub const Shape = struct {
    name: []const u8,
    State: type,
    /// `void` when the method takes no argument.
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

/// The method's declared name, recovered from a generic type's rendered name.
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

/// Validate `cx.on`'s options at comptime: only `.arg` and `.entity`.
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

/// Build a handler. `Cx.on` adds the safety-mode state check around this.
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

/// Pack an argument of at most 8 bytes. Unused bytes stay zero, so equal
/// arguments pack to equal values (CLAUDE.md §21).
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
    // Goal: the four shapes call the method with the right values, and
    // every invocation requests a render. Method: a state that records calls.
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
    var store = Store.init(State, &state);
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
