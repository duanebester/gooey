//! The app store and its entry points (contract §7).
//!
//! `App(State, config)` owns the root state, the store handlers resolve
//! against, the shared atlases and text system, and the window. The root
//! render function is `App`'s second argument, passed positionally as in
//! 0.3.1's `gooey.App` (contract §7, decision 7); nothing is found by name.
//!
//! Initialization runs through the lifecycle guard. Everything the app will
//! ever use is reserved before `on_init` returns; the guard then enters
//! `running` and any later allocation panics (contract rule 2).

const std = @import("std");
const builtin = @import("builtin");
const limits_mod = @import("limits.zig");
const handler_mod = @import("handler.zig");
const element = @import("element.zig");
const window_mod = @import("window.zig");
const tick_mod = @import("tick.zig");
const lifecycle = @import("lifecycle.zig");
const cx_mod = @import("cx.zig");
const keymap_mod = @import("keymap.zig");
const app_resources = @import("../context/app_resources.zig");
const text_mod = @import("../text/mod.zig");
const web_host = @import("../platform/web/core_host.zig");
const entities_mod = @import("entities.zig");
const text_engine = @import("text_engine.zig");

const assert = std.debug.assert;

pub const ResourceLimits = limits_mod.ResourceLimits;
pub const FontLimits = limits_mod.FontLimits;
/// A family for `Fonts.mono`: an installed name or a platform family.
pub const FontSource = text_mod.TextSystem.FaceSource;
pub const Theme = element.Theme;
pub const Effects = handler_mod.Effects;
pub const Window = window_mod.Window;
pub const Cx = cx_mod.Cx;

/// A keymap entry (contract §7): `.{ .keys = "cmd-z", .action = ui.action(Undo) }`.
pub const Binding = keymap_mod.Binding;

/// The app's comptime configuration (contract §7, decision 10). Only `title`,
/// `width`, `height`, and `limits` are required; every default below is the
/// reviewed policy (CLAUDE.md §19).
pub fn Config(comptime State: type) type {
    return struct {
        title: []const u8,
        width: u32,
        height: u32,
        limits: ResourceLimits,
        theme: *const Theme = &Theme.light,
        keymap: []const Binding = &.{},
        entities: []const type = &.{},
        fonts: Fonts = .{},
        on_init: ?*const fn (state: *State, effects: *Effects) void = null,
    };
}

/// The app's font families and faces (decisions 8 and 10). The defaults load
/// the platform's sans-serif at the theme's `font_size_base`, no second
/// family, and the `limits` profile's faces.
pub const Fonts = struct {
    /// Family name; null loads the platform's sans-serif.
    name: ?[]const u8 = null,
    /// Points, for both families; null takes the theme's `font_size_base`.
    size: ?f32 = null,
    /// The second family (decision 8); null reserves no faces.
    mono: ?FontSource = null,
    /// The faces to reserve; null keeps the `limits` profile's set.
    limits: ?FontLimits = null,
};

/// The font faces for `limits`: the `FontLimits` profile with the same name
/// as the `ResourceLimits` profile `limits` equals, else `standard`.
pub fn fontLimitsFor(comptime limits: ResourceLimits) FontLimits {
    for (ResourceLimits.profile_names) |name| {
        if (std.meta.eql(@field(ResourceLimits, name), limits)) return @field(FontLimits, name);
    }
    return FontLimits.standard;
}

/// The point size the app loads its families at.
fn fontSize(comptime State: type, comptime config: Config(State)) f32 {
    return config.fonts.size orelse @floatFromInt(config.theme.font_size_base);
}

/// The faces the app reserves.
fn fontFaces(comptime State: type, comptime config: Config(State)) FontLimits {
    return config.fonts.limits orelse fontLimitsFor(config.limits);
}

/// Reject font settings that cannot work, naming the field (decision 8): a
/// second family needs mono faces to load into, and mono faces need a family.
fn checkFonts(comptime State: type, comptime config: Config(State)) void {
    comptime {
        const size = fontSize(State, config);
        if (!(size > 0 and size < 1000)) {
            @compileError("gooey.App: fonts.size must be in (0, 1000) points");
        }
        if (config.fonts.name) |name| {
            if (name.len == 0) {
                @compileError("gooey.App: fonts.name is empty; use null for sans-serif");
            }
            if (name.len > text_mod.TextSystem.family_name_bytes_max) {
                @compileError("gooey.App: fonts.name names a family longer than 255 bytes");
            }
        }
        const faces = fontFaces(State, config);
        faces.validate();
        const mono_faces = faces.mono_variants.len;
        if (config.fonts.mono != null and mono_faces == 0) {
            @compileError("gooey.App: fonts.mono is set but fonts.limits.mono_variants is " ++
                "empty; set .fonts.limits with the mono variants to load");
        }
        if (config.fonts.mono == null and mono_faces > 0) {
            @compileError("gooey.App: fonts.limits.mono_variants reserves faces but " ++
                "fonts.mono is null");
        }
    }
}

/// Pools the framework registers beside the app's: the input, area, and
/// editor engines.
const engine_pool_count_max: u32 = 3;

/// Reject an entity list that cannot work (decision 17), naming the type.
fn checkEntities(comptime State: type, comptime types: []const type) void {
    comptime {
        if (types.len + engine_pool_count_max > handler_mod.entity_pool_count_max) {
            @compileError("gooey.App: more entity types than entity_pool_count_max " ++
                "allows beside the text-engine pools");
        }
        for (types, 0..) |T, index| {
            const name = @typeName(T);
            if (@typeInfo(T) != .@"struct") {
                @compileError("gooey.App: entity type " ++ name ++ " is not a struct");
            }
            if (T == State) @compileError("gooey.App: the root State cannot be an entity");
            if (T == text_engine.InputEngine or T == text_engine.AreaEngine or
                T == text_engine.EditorEngine)
            {
                @compileError("gooey.App: " ++ name ++ " is a text engine, not an entity");
            }
            if (@alignOf(T) > entities_mod.value_alignment) {
                @compileError("gooey.App: entity type " ++ name ++ " needs alignment above 16");
            }
            for (types[0..index]) |Earlier| {
                if (Earlier == T) {
                    @compileError("gooey.App: entity type " ++ name ++ " is listed twice");
                }
            }
        }
    }
}

pub fn App(
    comptime State: type,
    comptime render_fn: fn (cx: *Cx) void,
    comptime config: Config(State),
) type {
    comptime {
        if (config.limits.check()) |violation| @compileError(violation.message());
        checkEntities(State, config.entities);
        assert(config.width > 0);
        assert(config.height > 0);
        checkFonts(State, config);
    }
    return struct {
        guard: lifecycle.LifecycleGuard,
        state: State,
        store: handler_mod.Store,
        /// One pool per `config.entities` type, in list order.
        entity_pools: [config.entities.len]entities_mod.Pool,
        resources: app_resources.AppResources,
        window: Window,

        const Self = @This();

        // The browser exports (`init`, `frame`, `resize`): the other half of
        // the generated entry point (contract §7, decision 9).
        comptime {
            if (builtin.cpu.arch.isWasm()) _ = web_host.Exports(Self);
        }

        pub const limits = config.limits;
        pub const title = config.title;
        pub const theme = config.theme;
        pub const width = config.width;
        pub const height = config.height;
        pub const font_limits = fontFaces(State, config);
        pub const keymap = keymap_mod.compile(config.keymap);

        /// The root render function.
        pub fn render(cx: *Cx) void {
            render_fn(cx);
        }

        pub const HeadlessOptions = struct {
            scale_factor: f32,
        };

        /// Initialize without a platform window: the TestBackend path. The
        /// app must stay at this address (handlers and `Cx` point into it).
        pub noinline fn initHeadless(
            self: *Self,
            backing: std.mem.Allocator,
            io: std.Io,
            options: HeadlessOptions,
        ) !void {
            assert(options.scale_factor > 0);
            self.beginInit(backing);
            try self.initCore(io, options.scale_factor);
            self.finishInit();
        }

        /// The generated entry point (contract §7): `pub const main =
        /// App.main;` in the root file. Runs on macOS, Linux (Wayland), and
        /// Windows. On WASM, JavaScript drives the app through the exports
        /// below instead, so `main` does nothing there.
        pub fn main(init: std.process.Init) !void {
            if (comptime builtin.cpu.arch.isWasm()) return;
            const host = switch (comptime builtin.os.tag) {
                .macos => @import("../platform/macos/core_host.zig"),
                .linux => @import("../platform/linux/core_host.zig"),
                .windows => @import("../platform/windows/core_host.zig"),
                else => @compileError("gooey.App.main runs on macOS, Linux, Windows, " ++
                    "and the web"),
            };
            const self = try init.gpa.create(Self);
            defer init.gpa.destroy(self);
            try host.run(Self, self, init.gpa, init.io);
        }

        /// Start initialization: every allocation from here to `finishInit`
        /// goes through the guard, including a platform window's.
        pub fn beginInit(self: *Self, backing: std.mem.Allocator) void {
            self.guard = lifecycle.LifecycleGuard.init(backing);
            assert(self.guard.lifecycle == .initializing);
        }

        /// Reserve the core's storage: state, store, shared resources, and
        /// the window, at `scale_factor` device pixels per logical pixel.
        pub fn initCore(self: *Self, io: std.Io, scale_factor: f32) !void {
            assert(self.guard.lifecycle == .initializing);
            assert(scale_factor > 0);
            const gpa = self.guard.allocator();
            self.state = .{};
            self.store = handler_mod.Store.init(State, &self.state);
            try self.initEntityPools(gpa);
            errdefer self.deinitEntityPools(gpa);
            try self.resources.initOwnedInPlace(gpa, io, scale_factor, .{
                .font_name = config.fonts.name,
                .font_size = fontSize(State, config),
                .limits = font_limits,
                .mono = config.fonts.mono,
            }, &config.limits.atlas);
            errdefer self.resources.deinit();
            try window_mod.initInPlace(&self.window, gpa, &.{
                .width = @floatFromInt(config.width),
                .height = @floatFromInt(config.height),
                .scale_factor = scale_factor,
                .limits = &config.limits,
                .theme = config.theme,
                .keymap = keymap,
                .store = &self.store,
                .resources = &self.resources,
            });
        }

        /// Run `on_init`, the last initialization work, then enter `running`:
        /// any later allocation through the guard panics.
        pub fn finishInit(self: *Self) void {
            assert(self.guard.lifecycle == .initializing);
            if (config.on_init) |on_init| {
                var effects = Effects.init(null, .root);
                effects.store = &self.store;
                on_init(&self.state, &effects);
                assert(effects.file_dialog == null);
                // Entities on_init removed leave before the first build.
                self.store.freeRemoved();
            }
            self.guard.enterRunning();
            assert(self.guard.lifecycle == .running);
        }

        /// Stop and free an app made by `initHeadless`: the TestBackend
        /// path has no host to stop it.
        pub fn deinitHeadless(self: *Self) void {
            self.stop();
            self.deinit();
            assert(self.guard.lifecycle == .deinitializing);
        }

        /// Leave `running`, the only way out of it: no tick runs afterwards,
        /// and frees through the guard are expected. A host defers it right
        /// after `finishInit`, so it runs before any deferred teardown frees
        /// the host, the platform window, or the core.
        pub fn stop(self: *Self) void {
            assert(self.guard.lifecycle == .running);
            assert(self.window.phase == .idle);
            self.guard.enterDeinitializing();
        }

        /// Free everything `initCore` reserved. A running app must `stop`
        /// first; an init that failed before `finishInit` is still
        /// initializing, and its teardown starts here.
        pub fn deinit(self: *Self) void {
            if (self.guard.lifecycle == .running) std.debug.panic("App.deinit on a " ++
                "running app: call App.stop first, before any teardown frees", .{});
            if (self.guard.lifecycle == .initializing) self.guard.enterDeinitializing();
            assert(self.guard.lifecycle == .deinitializing);
            window_mod.deinit(&self.window);
            self.resources.deinit();
            self.deinitEntityPools(self.guard.allocator());
        }

        /// Reserve and register one pool per `config.entities` type,
        /// `limits.entities.count_per_type_max` slots each (decision 17).
        fn initEntityPools(self: *Self, gpa: std.mem.Allocator) !void {
            const count = config.limits.entities.count_per_type_max;
            comptime assert(count > 0);
            inline for (config.entities, 0..) |T, index| {
                const pool = &self.entity_pools[index];
                errdefer for (self.entity_pools[0..index]) |*done| done.deinit(gpa);
                const stride: u32 = @sizeOf(T);
                try pool.initInPlace(gpa, @typeName(T), stride, count);
                self.store.registerPool(.{
                    .type_id = handler_mod.typeId(T),
                    .name = pool.name,
                    .base = pool.bytes.ptr,
                    .stride = stride,
                    .generations = pool.generations,
                    .app_pool = pool,
                });
            }
            assert(self.store.pool_count == config.entities.len);
        }

        fn deinitEntityPools(self: *Self, gpa: std.mem.Allocator) void {
            for (&self.entity_pools) |*pool| pool.deinit(gpa);
        }

        pub fn tick(self: *Self, now_ns: u64) void {
            assert(self.guard.lifecycle == .running);
            tick_mod.tick(self, &self.window, now_ns);
        }

        /// The main-thread side of a tick, for a host with a render thread.
        /// Type-erased so the host is not generic over the app.
        pub fn tickMainErased(context: *anyopaque, now_ns: u64) void {
            const self: *Self = @ptrCast(@alignCast(context));
            assert(self.guard.lifecycle == .running);
            _ = tick_mod.tickMain(self, &self.window, now_ns);
        }
    };
}
