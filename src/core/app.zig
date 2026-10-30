//! The app store and its entry points (contract §7).
//!
//! `App(State, config)` owns the root state, the store handlers resolve
//! against, the shared atlases and text system, and the window. The root
//! render function is the root file's `pub fn render(cx: *Cx) void`, the
//! same function the contract's acceptance example declares; tests and the
//! goldens pass it explicitly through `Headless`.
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

pub fn App(comptime State: type, comptime config: Config(State)) type {
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
        pub const width = config.width;
        pub const height = config.height;
        pub const font_limits = fontLimitsFor(config.limits);

        /// The root render function, from the root file.
        pub fn render(cx: *Cx) void {
            const root = @import("root");
            if (!@hasDecl(root, "render")) {
                @compileError("gooey.App needs `pub fn render(cx: *gooey.Cx) void` " ++
                    "in the root file");
            }
            root.render(cx);
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
            self.guard = lifecycle.LifecycleGuard.init(backing);
            const gpa = self.guard.allocator();
            self.state = .{};
            self.store = handler_mod.Store.init(State, &self.state);
            try self.resources.initOwnedInPlace(gpa, io, options.scale_factor, .{
                .font_name = null,
                .font_size = @floatFromInt(config.theme.font_size_base),
                .limits = font_limits,
            }, &config.limits.atlas);
            errdefer self.resources.deinit();
            try window_mod.initInPlace(&self.window, gpa, &.{
                .width = @floatFromInt(config.width),
                .height = @floatFromInt(config.height),
                .scale_factor = options.scale_factor,
                .limits = &config.limits,
                .theme = config.theme,
                .store = &self.store,
                .resources = &self.resources,
            });
            errdefer window_mod.deinit(&self.window);
            if (config.on_init) |on_init| {
                var effects = Effects.init(null, .root);
                on_init(&self.state, &effects);
                assert(effects.file_dialog == null);
            }
            self.guard.enterRunning();
            assert(self.guard.lifecycle == .running);
        }

        pub fn deinit(self: *Self) void {
            assert(self.guard.lifecycle == .running);
            self.guard.enterDeinitializing();
            window_mod.deinit(&self.window);
            self.resources.deinit();
        }

        /// One tick with `render_fn` as the root render function.
        pub fn tickWith(self: *Self, comptime render_fn: fn (cx: *Cx) void, now_ns: u64) void {
            assert(self.guard.lifecycle == .running);
            const Root = struct {
                pub fn render(cx: *Cx) void {
                    render_fn(cx);
                }
            };
            var root = Root{};
            tick_mod.tick(&root, &self.window, now_ns);
        }

        pub fn tick(self: *Self, now_ns: u64) void {
            assert(self.guard.lifecycle == .running);
            tick_mod.tick(self, &self.window, now_ns);
        }
    };
}
