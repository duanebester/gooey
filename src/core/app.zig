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
const app_resources = @import("../context/app_resources.zig");

const assert = std.debug.assert;

pub const ResourceLimits = limits_mod.ResourceLimits;
pub const FontLimits = limits_mod.FontLimits;
pub const Theme = element.Theme;
pub const Effects = handler_mod.Effects;
pub const Window = window_mod.Window;
pub const Cx = cx_mod.Cx;

/// A keymap binding. Keymaps arrive with the router's keymap support in
/// phase 4; milestone 1 requires `config.keymap` to be empty.
pub const Binding = struct { key_context: element.KeyContext, action: u64 };

pub fn Config(comptime State: type) type {
    return struct {
        title: []const u8,
        width: u32,
        height: u32,
        limits: ResourceLimits,
        theme: *const Theme,
        keymap: []const Binding,
        entities: []const type,
        on_init: ?*const fn (state: *State, effects: *Effects) void,
    };
}

/// The font faces for `limits`: the `FontLimits` profile with the same name
/// as the `ResourceLimits` profile `limits` equals, else `standard`.
pub fn fontLimitsFor(comptime limits: ResourceLimits) FontLimits {
    for (ResourceLimits.profile_names) |name| {
        if (std.meta.eql(@field(ResourceLimits, name), limits)) return @field(FontLimits, name);
    }
    return FontLimits.standard;
}

pub fn App(
    comptime State: type,
    comptime render_fn: fn (cx: *Cx) void,
    comptime config: Config(State),
) type {
    comptime {
        if (config.limits.check()) |violation| @compileError(violation.message());
        if (config.keymap.len > 0) @compileError("gooey.App: keymaps arrive in phase 4");
        if (config.entities.len > 0) @compileError("gooey.App: entities arrive in phase 4");
        assert(config.width > 0);
        assert(config.height > 0);
    }
    return struct {
        guard: lifecycle.LifecycleGuard,
        state: State,
        store: handler_mod.Store,
        resources: app_resources.AppResources,
        window: Window,

        const Self = @This();

        pub const limits = config.limits;
        pub const title = config.title;
        pub const theme = config.theme;
        pub const width = config.width;
        pub const height = config.height;
        pub const font_limits = fontLimitsFor(config.limits);

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
        /// App.main;` in the root file. Runs on macOS and Linux (Wayland);
        /// Windows and the web move onto the core later in phase 4.
        pub fn main(init: std.process.Init) !void {
            const host = switch (comptime builtin.os.tag) {
                .macos => @import("../platform/macos/core_host.zig"),
                .linux => @import("../platform/linux/core_host.zig"),
                else => @compileError("gooey.App.main runs on macOS and Linux; Windows " ++
                    "and the web move onto the core later in phase 4"),
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
            try self.resources.initOwnedInPlace(gpa, io, scale_factor, .{
                .font_name = null,
                .font_size = @floatFromInt(config.theme.font_size_base),
                .limits = font_limits,
            }, &config.limits.atlas);
            errdefer self.resources.deinit();
            try window_mod.initInPlace(&self.window, gpa, &.{
                .width = @floatFromInt(config.width),
                .height = @floatFromInt(config.height),
                .scale_factor = scale_factor,
                .limits = &config.limits,
                .theme = config.theme,
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
                on_init(&self.state, &effects);
                assert(effects.file_dialog == null);
            }
            self.guard.enterRunning();
            assert(self.guard.lifecycle == .running);
        }

        /// Free everything `initCore` reserved; also valid when a later init
        /// step failed before `finishInit`.
        pub fn deinit(self: *Self) void {
            assert(self.guard.lifecycle != .deinitializing);
            self.guard.enterDeinitializing();
            window_mod.deinit(&self.window);
            self.resources.deinit();
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
