const std = @import("std");
const builtin = @import("builtin");
const limits_mod = @import("limits.zig");
const handler_mod = @import("handler.zig");
const element = @import("element.zig");
const window_mod = @import("window.zig");
const tick_mod = @import("tick.zig");
const debugger = @import("debugger.zig");
const lifecycle = @import("lifecycle.zig");
const cx_mod = @import("cx.zig");
const keymap_mod = @import("keymap.zig");
const app_resources = @import("app_resources.zig");
const text_mod = @import("../text/mod.zig");
const web_host = @import("../platform/web/core_host.zig");
const entities_mod = @import("entities.zig");
const text_engine = @import("text_engine.zig");
const jobs_mod = @import("jobs.zig");
const images = @import("images.zig");

const assert = std.debug.assert;

pub const ResourceLimits = limits_mod.ResourceLimits;
pub const FontLimits = limits_mod.FontLimits;
pub const FontSource = text_mod.TextSystem.FaceSource;
pub const Theme = element.Theme;
pub const TitleBar = @import("events.zig").TitleBar;
pub const Effects = handler_mod.Effects;
pub const Window = window_mod.Window;
pub const Cx = cx_mod.Cx;

pub const Init = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
};

const environ_empty: std.process.Environ.Map = .{
    .array_hash_map = .empty,
    .allocator = std.mem.Allocator.failing,
};

pub const Binding = keymap_mod.Binding;

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
        title_bar: TitleBar = .standard,
        min_width: u32 = 0,
        min_height: u32 = 0,
        jobs: []const type = &.{},
        on_init: ?*const fn (state: *State, init: Init, effects: *Effects) void = null,
        on_deinit: ?*const fn (state: *State) void = null,
    };
}

pub const Fonts = struct {
    name: ?[]const u8 = null,
    size: ?f32 = null,
    mono: ?FontSource = null,
};

fn fontSize(comptime State: type, comptime config: Config(State)) f32 {
    return config.fonts.size orelse @floatFromInt(config.theme.font_size_base);
}

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
        const mono_faces = config.limits.text.fonts.mono_variants.len;
        if (config.fonts.mono != null and mono_faces == 0) {
            @compileError("gooey.App: fonts.mono is set but limits.text.fonts.mono_variants " ++
                "is empty; list the mono variants to load there");
        }
        if (config.fonts.mono == null and mono_faces > 0) {
            @compileError("gooey.App: limits.text.fonts.mono_variants reserves faces but " ++
                "fonts.mono is null");
        }
    }
}

fn checkMinSize(comptime State: type, comptime config: Config(State)) void {
    comptime {
        const window = config.limits.window;
        if (config.min_width > config.width) {
            @compileError(std.fmt.comptimePrint("gooey.App: min_width {d} is above " ++
                "width {d}", .{ config.min_width, config.width }));
        }
        if (config.min_height > config.height) {
            @compileError(std.fmt.comptimePrint("gooey.App: min_height {d} is above " ++
                "height {d}", .{ config.min_height, config.height }));
        }
        if (config.min_width > window.framebuffer_width_max) {
            @compileError(std.fmt.comptimePrint("gooey.App: min_width {d} is above " ++
                "ResourceLimits.window.framebuffer_width_max {d}", .{
                config.min_width,
                window.framebuffer_width_max,
            }));
        }
        if (config.min_height > window.framebuffer_height_max) {
            @compileError(std.fmt.comptimePrint("gooey.App: min_height {d} is above " ++
                "ResourceLimits.window.framebuffer_height_max {d}", .{
                config.min_height,
                window.framebuffer_height_max,
            }));
        }
    }
}

fn checkJobs(comptime types: []const type, comptime limits: *const ResourceLimits) void {
    comptime {
        for (types, 0..) |T, index| {
            jobs_mod.checkSpec(T);
            const name = @typeName(T);
            if (@sizeOf(T.Input) > limits.events.job_input_bytes_max) {
                @compileError(std.fmt.comptimePrint("gooey.App: job {s}'s Input is {d} " ++
                    "bytes, above ResourceLimits.events.job_input_bytes_max {d}", .{
                    name,
                    @sizeOf(T.Input),
                    limits.events.job_input_bytes_max,
                }));
            }
            if (@sizeOf(T.Result) > limits.events.job_result_bytes_max) {
                @compileError(std.fmt.comptimePrint("gooey.App: job {s}'s Result is {d} " ++
                    "bytes, above ResourceLimits.events.job_result_bytes_max {d}", .{
                    name,
                    @sizeOf(T.Result),
                    limits.events.job_result_bytes_max,
                }));
            }
            if (T.posts_max > limits.events.job_result_count_max) {
                @compileError(std.fmt.comptimePrint("gooey.App: job {s}'s posts_max is {d}, " ++
                    "above ResourceLimits.events.job_result_count_max {d}: on the main " ++
                    "thread one run could never start", .{
                    name,
                    T.posts_max,
                    limits.events.job_result_count_max,
                }));
            }
            for (types[0..index]) |Earlier| {
                if (Earlier == T) {
                    @compileError("gooey.App: job type " ++ name ++ " is listed twice");
                }
            }
        }
    }
}

const engine_pool_count_max: u32 = 3;

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
        if (config.limits.check()) |violation| @compileError(violation.describe());
        if (debugger.withHeadroom(&config.limits).check()) |violation| {
            @compileError(std.fmt.comptimePrint("the budget must leave the debugger " ++
                "overlay's headroom ({d} quads, {d} glyphs, {d} paint records) below the " ++
                "framework ceilings; Debug and ReleaseSafe reserve it on top of the app's " ++
                "limits (contract decision 16), so `.ceiling` is not an app profile: {s}", .{
                debugger.overlay_quad_count_max,
                debugger.overlay_glyph_count_max,
                debugger.overlay_paint_record_count_max,
                violation.describe(),
            }));
        }
        checkEntities(State, config.entities);
        checkJobs(config.jobs, &config.limits);
        assert(config.width > 0);
        assert(config.height > 0);
        checkFonts(State, config);
        checkMinSize(State, config);
    }
    return struct {
        guard: lifecycle.LifecycleGuard,
        state: State,
        store: handler_mod.Store,
        store_pools: [config.entities.len + engine_pool_count_max]handler_mod.EntityPool,
        entity_pools: [config.entities.len]entities_mod.Pool,
        resources: app_resources.AppResources,
        window: Window,
        process: Init,
        job_type_ids: [config.jobs.len]usize,

        const Self = @This();

        comptime {
            if (builtin.cpu.arch.isWasm()) _ = web_host.Exports(Self);
        }

        pub const limits = config.limits;
        pub const limits_reserved = debugger.reservedLimits(&config.limits);
        pub const title = config.title;
        pub const theme = config.theme;
        pub const title_bar = config.title_bar;
        pub const min_width = config.min_width;
        pub const min_height = config.min_height;
        pub const width = config.width;
        pub const height = config.height;
        pub const font_limits = config.limits.text.fonts;
        pub const keymap = keymap_mod.compile(config.keymap);

        pub fn render(cx: *Cx) void {
            render_fn(cx);
        }

        pub const HeadlessOptions = struct {
            scale_factor: f32,
            image_decodes: images.Mode = .worker,
            job_runs: jobs_mod.Mode = .host,
        };

        pub noinline fn initHeadless(
            self: *Self,
            backing: std.mem.Allocator,
            io: std.Io,
            options: HeadlessOptions,
        ) !void {
            assert(options.scale_factor > 0);
            self.process = .{ .io = io, .environ = &environ_empty };
            self.beginInit(backing);
            try self.initCoreWith(io, &options);
            self.finishInit();
        }

        pub fn main(init: std.process.Init) !void {
            if (comptime builtin.cpu.arch.isWasm()) return;
            const host = switch (comptime builtin.os.tag) {
                .macos => @import("../platform/macos/core_host.zig"),
                .linux => switch (@import("../platform/linux_backend.zig").selected) {
                    .wayland_vulkan, .wayland_cpu => @import("../platform/linux/core_host.zig"),
                    .fbdev => @import("../platform/fbdev/core_host.zig"),
                    .eve => @import("../platform/eve/core_host.zig"),
                },
                .windows => @import("../platform/windows/core_host.zig"),
                else => @compileError("gooey.App.main runs on macOS, Linux, Windows, " ++
                    "and the web"),
            };
            const self = try init.gpa.create(Self);
            defer init.gpa.destroy(self);
            self.process = .{ .io = init.io, .environ = init.environ_map };
            try host.run(Self, self, init.gpa, init.io);
        }

        pub fn beginInit(self: *Self, backing: std.mem.Allocator) void {
            self.guard = lifecycle.LifecycleGuard.init(backing);
            assert(self.guard.lifecycle == .initializing);
        }

        pub fn initCore(self: *Self, io: std.Io, scale_factor: f32) !void {
            assert(scale_factor > 0);
            try self.initCoreWith(io, &.{
                .scale_factor = scale_factor,
                .image_decodes = .worker,
                .job_runs = .host,
            });
        }

        fn initCoreWith(self: *Self, io: std.Io, options: *const HeadlessOptions) !void {
            assert(self.guard.lifecycle == .initializing);
            assert(options.scale_factor > 0);
            const scale_factor = options.scale_factor;
            const gpa = self.guard.allocator();
            self.state = .{};
            inline for (config.jobs, 0..) |T, index| {
                self.job_type_ids[index] = handler_mod.typeId(T);
            }
            self.store = handler_mod.Store.init(State, &self.state, &self.store_pools);
            try self.initEntityPools(gpa);
            errdefer self.deinitEntityPools(gpa);
            try self.resources.initOwnedInPlace(gpa, io, scale_factor, .{
                .font_name = config.fonts.name,
                .font_size = fontSize(State, config),
                .text = &config.limits.text,
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
                .job_types = &self.job_type_ids,
                .image_decodes = options.image_decodes,
                .job_runs = options.job_runs,
            });
        }

        pub fn setBrowserProcess(self: *Self, io: std.Io) void {
            assert(comptime builtin.cpu.arch.isWasm());
            self.process = .{ .io = io, .environ = &environ_empty };
        }

        pub fn finishInit(self: *Self) void {
            assert(self.guard.lifecycle == .initializing);
            if (config.on_init) |on_init| {
                var effects = Effects.init(null, .root);
                effects.store = &self.store;
                effects.jobs = &self.window.jobs;
                on_init(&self.state, self.process, &effects);
                assert(effects.file_dialog == null);
                self.store.freeRemoved();
            }
            self.guard.enterRunning();
            assert(self.guard.lifecycle == .running);
        }

        pub fn deinitHeadless(self: *Self) void {
            self.stop();
            self.deinit();
            assert(self.guard.lifecycle == .deinitializing);
        }

        pub fn stop(self: *Self) void {
            assert(self.guard.lifecycle == .running);
            assert(self.window.phase == .idle);
            self.window.jobs.stop();
            self.guard.enterDeinitializing();
            if (config.on_deinit) |on_deinit| on_deinit(&self.state);
            assert(self.window.jobs.stopped);
        }

        pub fn deinit(self: *Self) void {
            if (self.guard.lifecycle == .running) std.debug.panic("App.deinit on a " ++
                "running app: call App.stop first, before any teardown frees", .{});
            if (self.guard.lifecycle == .initializing) self.guard.enterDeinitializing();
            assert(self.guard.lifecycle == .deinitializing);
            window_mod.deinit(&self.window);
            self.resources.deinit();
            self.deinitEntityPools(self.guard.allocator());
        }

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

        pub fn tickMainErased(context: *anyopaque, now_ns: u64) void {
            const self: *Self = @ptrCast(@alignCast(context));
            assert(self.guard.lifecycle == .running);
            _ = tick_mod.tickMain(self, &self.window, now_ns);
        }
    };
}
