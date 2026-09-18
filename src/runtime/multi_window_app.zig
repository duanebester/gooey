//! Multi-Window App - High-level API for managing multiple windows
//!
//! This module provides the `App` struct which enables multi-window applications
//! with shared resources. Each window has its own state and render function,
//! while expensive resources (text system, atlases) are shared.
//!
//! ## Architecture
//!
//! The App struct centralizes:
//! - Platform lifecycle (init/deinit/run)
//! - Window creation and teardown (identity lives in the platform registry)
//! - Shared resources (text system, SVG atlas, image atlas)
//! - Quit behavior (quit when last window closes)
//!
//! ## Usage
//!
//! ```zig
//! var app: App = undefined;
//! try app.initInPlace(allocator, .{ .font_size = 16.0 }, io);
//! defer app.deinit();
//!
//! const main_handle = try app.openWindow(MainState, &main_state, mainRender, .{
//!     .title = "Main Window",
//! });
//!
//! // Later, open another window:
//! const dialog_handle = try app.openWindow(DialogState, &dialog_state, dialogRender, .{
//!     .title = "Dialog",
//!     .width = 400,
//!     .height = 300,
//! });
//!
//! app.run();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Platform
const platform = @import("../platform/mod.zig");
const Platform = platform.Platform;
// `PlatformWindow` is the OS-level handle; `Window` is the framework wrapper.
const PlatformWindow = platform.PlatformWindow;
const WindowId = platform.WindowId;
const WindowRegistry = platform.WindowRegistry;
const WindowOptions = platform.WindowOptions;
// One canonical glass style shared by every backend. `AppWindowOptions`
// re-exposes this exact type so `openWindow` can forward the value instead of
// reinterpreting tags across two independently ordered enums.
const GlassStyle = platform.GlassStyle;

// Core
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const shader_mod = @import("../core/shader.zig");

// Bundle the three "expensive to duplicate per window" resources (text system
// + svg atlas + image atlas) into a single `AppResources` field, owned once on
// `App` and lent as borrowed views to each `Window`. The types are reached
// through `AppResources`, never named directly here.
const app_resources_mod = @import("../context/app_resources.zig");
const AppResources = app_resources_mod.AppResources;

// `context.App` owns application-lifetime state shared across windows
// (entities, keymap, globals, image loader). Embedded by-value below so every
// `Window` borrows `&self.context_app` and reaches the same `EntityMap` — the
// property cross-window observation needs.
const context_app_mod = @import("../context/app.zig");
const ContextApp = context_app_mod.App;

// Runtime
const WindowContext = @import("window_context.zig").WindowContext;
const WindowHandle = @import("window_handle.zig").WindowHandle;

// Context
const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;
const handler_mod = @import("../context/handler.zig");
const window_mod = @import("../context/window.zig");
const FontConfig = window_mod.FontConfig;

// Input
const input_mod = @import("../input/mod.zig");
const InputEvent = input_mod.InputEvent;

// =============================================================================
// Constants (per CLAUDE.md: "put a limit on everything")
// =============================================================================

/// Maximum number of windows an App can manage.
///
/// Pinned to the platform registry's own bound: the platform assigns window
/// identity, so admitting a window the platform cannot register would fail
/// deeper in the stack with a worse diagnostic.
pub const MAX_WINDOWS: u32 = WindowRegistry.MAX_WINDOWS;

/// Default window dimensions
const DEFAULT_WIDTH: f64 = 800;
const DEFAULT_HEIGHT: f64 = 600;

/// Largest backing-scale factor any backend admits.
///
/// Pinned to the loosest backend bound (macOS `getScaleFactor` asserts 8.0, and
/// web's `scale_factor_max` is 8.0) rather than a tighter guess: a shared-code
/// assertion stricter than the boundary it consumes turns a host reporting, say,
/// 5x into a panic in code that never touched the host at all.
const SCALE_FACTOR_MAX: f64 = 8.0;

/// Type-erased teardown for one window's `WindowContext(State)`.
///
/// Takes the platform window because that is where the context is reachable
/// from without naming `State`: it is the window's user data.
const ContextTeardownFn = *const fn (*PlatformWindow) void;

/// Whether losing the last window should stop the application.
///
/// Three named states rather than a `bool`, because the right answer is
/// platform-dependent and a boolean has to pick one default that is wrong
/// somewhere. macOS applications outlive their windows — Finder, Safari, and
/// Mail all keep a menu bar with nothing open, and AppKit's own
/// `applicationShouldTerminateAfterLastWindowClosed` defaults to `NO`. Linux
/// and Windows applications exit.
///
/// `App` previously hardcoded `quit_when_last_window_closes = true` on every
/// target, which made every macOS Gooey application non-native in a way an
/// author could only discover by reading `checkQuitCondition`.
pub const QuitPolicy = enum {
    /// Follow platform convention: stay alive on macOS, quit elsewhere.
    platform_default,

    /// Quit as soon as the last window closes, on every platform.
    last_window_closed,

    /// Never quit because of window count. Only `App.quit` stops the app.
    explicit,

    /// Resolve this policy against the build target.
    ///
    /// Pure, and the only place `platform_default` is interpreted, so the
    /// convention lives in exactly one expression.
    pub fn quitsOnLastWindowClosed(self: QuitPolicy) bool {
        return switch (self) {
            .platform_default => !platform.is_macos,
            .last_window_closed => true,
            .explicit => false,
        };
    }
};

// =============================================================================
// App
// =============================================================================

/// Multi-window application manager.
///
/// Owns the platform and the shared resources. Each window gets its own
/// WindowContext with state and render function.
///
/// An `App` must never be moved after `initInPlace`: `self.platform` is
/// initialized against its final address and native listeners capture it.
pub const App = struct {
    /// Memory allocator for app resources
    allocator: Allocator,

    /// Platform instance (event loop, window creation, window identity).
    ///
    /// The platform's window registry is the single source of truth for window
    /// identity. `App` deliberately keeps no second registry: `PlatformWindow.init`
    /// registers itself and `getWindowId()` returns the platform-assigned id, so a
    /// parallel app-side registry would hand out a second, diverging id sequence.
    platform: Platform,

    /// Platform-assigned ids of the windows this app opened, for teardown.
    ///
    /// This is an enumeration aid, not an identity registry: every entry is an
    /// id the platform minted. The platform contract exposes lookup and counting
    /// but no iterator, and `closeAllWindows` must visit each window exactly
    /// once, so the ids are mirrored here under the same hard bound. Entries
    /// `[0..open_window_count]` are live; the tail is `.invalid`.
    open_window_ids: [MAX_WINDOWS]WindowId,

    /// Per-window context teardown, parallel to `open_window_ids`.
    ///
    /// `App` is deliberately not generic over `State`, but `WindowContext` is,
    /// so `App` cannot name the context type it has to free. `openWindow` is
    /// generic, so it parks a monomorphised thunk here instead; the thunk
    /// recovers the context from the window's user data, which is where every
    /// window callback already recovers it from. Entries `[0..open_window_count]`
    /// are non-null; the tail is `null`. One word per slot, reserved with the
    /// rest of `App`, so teardown never allocates.
    open_window_teardowns: [MAX_WINDOWS]?ContextTeardownFn,

    /// Number of live entries in `open_window_ids` and `open_window_teardowns`.
    open_window_count: u32,

    // =========================================================================
    // Shared Resources (expensive to duplicate per window)
    // =========================================================================

    /// Shared rendering resources owned at app scope. Every per-window `Window`
    /// embeds a borrowed view over the same pointees; `AppResources.deinit`
    /// tears them down once, in `App.deinit`, after the last window closes.
    resources: AppResources,

    /// Application-lifetime state shared across windows (entities, keymap,
    /// globals, image loader). Embedded by-value: `&self.context_app` outlives
    /// every `Window` opened from this app, making models observable across
    /// windows.
    context_app: ContextApp,

    /// IO interface for async work. Threaded through to all windows.
    io: std.Io,

    // =========================================================================
    // App State
    // =========================================================================

    /// When losing the last window should stop the application.
    ///
    /// `initInPlace` sets `.platform_default`; there is no field default
    /// because the struct is never built as a literal. Assign before `run` to
    /// override.
    quit_policy: QuitPolicy,

    /// Is the app currently running?
    running: bool,

    /// Has the app been initialized?
    initialized: bool,

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Initialize a multi-window App in place.
    ///
    /// `self` must point at uninitialized memory that outlives the event loop;
    /// every field is written here. In-place init is viral (CLAUDE.md §13):
    /// `Platform` must be initialized at its final address because native
    /// registry listeners and window delegates capture `&self.platform`, so a
    /// by-value `App.init` that returned a `Self` literal left those listeners
    /// pointing into a dead stack frame. That is also why no struct literal is
    /// built below — a literal would be a movable stack temporary.
    pub fn initInPlace(
        self: *Self,
        allocator: Allocator,
        font_config: FontConfig,
        io: std.Io,
    ) !void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(font_config.font_size > 0);
        std.debug.assert(font_config.font_size < 1000);

        try self.platform.initInPlace(allocator);
        errdefer self.platform.deinit();

        // Create text + SVG + image atlases in one call. Scale is `1.0` here;
        // the first window's scale factor is installed later in `openWindow`
        // once a platform window exists to read `scale_factor` from.
        try self.resources.initOwnedInPlace(allocator, io, 1.0, .{
            .font_name = font_config.font_name,
            .font_size = font_config.font_size,
        });
        errdefer self.resources.deinit();

        // May fail with `OutOfMemory` (it registers an owned `Keymap` in
        // `app.globals`); it unwinds its own allocations on its error path.
        try self.context_app.initInPlace(allocator, io);
        errdefer self.context_app.deinit();

        // Infallible tail: plain field writes, so nothing below can unwind.
        self.allocator = allocator;
        self.io = io;
        self.open_window_ids = @splat(.invalid);
        self.open_window_teardowns = @splat(null);
        self.open_window_count = 0;
        self.quit_policy = .platform_default;
        self.running = false;
        self.initialized = true;

        // Pair-assert: post-init pointers must be non-null, and no window can
        // exist yet on either side of the boundary.
        std.debug.assert(@intFromPtr(self.resources.text_system) != 0);
        std.debug.assert(@intFromPtr(self.resources.svg_atlas) != 0);
        std.debug.assert(@intFromPtr(self.resources.image_atlas) != 0);
        std.debug.assert(self.platform.windowCount() == 0);
        std.debug.assert(self.open_window_count == 0);
    }

    /// Clean up all app resources.
    ///
    /// Closes all windows and frees shared resources.
    pub fn deinit(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.initialized);
        std.debug.assert(self.open_window_count <= MAX_WINDOWS);

        // Close all windows first — every per-window `Window` holds a
        // borrowed view of `self.resources` and `&self.context_app`;
        // closing the windows before tearing either down ensures no
        // in-flight render can still reach a freed atlas, and no
        // `Window.deinit` can still walk a freed `EntityMap`.
        self.closeAllWindows();
        std.debug.assert(self.open_window_count == 0);

        // Tear the shared `EntityMap` down before the atlases: `EntityMap.deinit`
        // cancels attached async groups that may hold pointers into the image
        // atlas's pixel buffers, so those tasks must unwind against a still-live
        // atlas to avoid use-after-free.
        self.context_app.deinit();

        // Frees text_system + svg_atlas + image_atlas in one call.
        self.resources.deinit();

        // Clean up platform. Its window registry is torn down inside
        // `Platform.deinit`; `closeAllWindows` above already withdrew every
        // window from it via `PlatformWindow.deinit`.
        self.platform.deinit();

        self.initialized = false;
    }

    // =========================================================================
    // Window Management
    // =========================================================================

    /// Open a new window with its own state and render function.
    ///
    /// Returns a typed handle for cross-window communication.
    /// The window will use shared resources (text system, atlases).
    pub fn openWindow(
        self: *Self,
        comptime State: type,
        state: *State,
        comptime render: fn (*Cx) void,
        options: AppWindowOptions,
    ) !WindowHandle(State) {
        // Assertions: validate inputs
        std.debug.assert(self.initialized);
        std.debug.assert(@intFromPtr(state) != 0);

        // Reclaim closed windows *before* the bound is checked: an app that
        // only ever closes windows through `WindowHandle.close` would otherwise
        // walk registry and slot table up to `MAX_WINDOWS` and then refuse to
        // open anything. Opening is a safe reclaim point — never inside the
        // dispatch of a window that already closed itself. No quit check:
        // close-then-reopen is legitimate, and quitting between the two would
        // tear the host down under the window being opened.
        _ = self.reclaimClosedWindows();

        // Enforce the bound against the platform registry, the authority that
        // will actually have to accept the registration.
        if (self.platform.windowCount() >= MAX_WINDOWS) {
            return error.TooManyWindows;
        }
        std.debug.assert(self.open_window_count < MAX_WINDOWS);

        // Named rather than an inline literal: the boundary takes
        // `*const WindowOptions` and the struct is far over the 16-byte
        // by-value threshold.
        const window_options = windowOptionsFrom(&options);

        // `PlatformWindow.init` registers itself with the platform and, where
        // the host requires it, routes input to itself — so there is no
        // Linux-only `plat.setActiveWindow(window)` follow-up here.
        var window = try PlatformWindow.init(self.allocator, &self.platform, &window_options);
        errdefer window.deinit();

        // The id comes from the platform, which minted it during
        // `PlatformWindow.init`. Taking it from `getWindowId()` rather than a
        // second app-side `register` call is what keeps `WindowHandle.id` and
        // `window.getWindowId()` the same value forever.
        const id = window.getWindowId();
        std.debug.assert(id.isValid());
        std.debug.assert(self.platform.getWindow(id) != null);

        // First window only: the shared resources were built at scale 1.0
        // before any window existed to read a real scale factor from. Keyed on
        // the app-side count because the platform already holds this window.
        if (self.open_window_count == 0) self.installScaleFactor(window);

        self.trackWindow(id, contextTeardown(State));
        errdefer self.untrackWindowId(id);

        // Create per-window context with shared resources
        const ctx = try self.createWindowContext(State, window, state, render);
        errdefer ctx.deinit();

        // Set user callbacks if provided
        ctx.setCallbacks(options.on_event, options.on_close, options.on_resize);

        // Connect context to window
        ctx.setupWindow(window);

        // Set up close callback to handle quit behavior
        window.setCloseCallback(closeCallback(State));

        // Assertions: validate result
        std.debug.assert(self.platform.getWindow(id) != null);
        std.debug.assert(self.open_window_count > 0);

        return WindowHandle(State).fromId(id);
    }

    /// Install the first window's scale factor on the shared resources.
    ///
    /// Reads through `getScaleFactor()` — the contract-verified accessor — so
    /// this cannot silently bind to a backend field that happens to share the
    /// name. The upper bound matches what the backends themselves accept
    /// (macOS asserts 8.0, web's `scale_factor_max` is 8.0); the previous 4.0
    /// here meant a host reporting 5x passed every backend check and then
    /// panicked in shared code.
    fn installScaleFactor(self: *Self, window: *PlatformWindow) void {
        const scale_factor = window.getScaleFactor();
        std.debug.assert(scale_factor > 0);
        std.debug.assert(scale_factor <= SCALE_FACTOR_MAX);

        const scale: f32 = @floatCast(scale_factor);
        self.resources.text_system.setScaleFactor(scale);
        self.resources.svg_atlas.setScaleFactor(scale);
        self.resources.image_atlas.setScaleFactor(scale_factor); // ImageAtlas uses f64
    }

    /// Ask a window to close, then reclaim every window whose close completed.
    ///
    /// The request goes through `PlatformWindow.close`, so a user `on_close`
    /// callback can still veto it; a vetoed window is left untouched.
    ///
    /// Precondition: the caller is not inside the dispatch of a window that is
    /// already closed. Teardown frees that window's `WindowContext`, and the
    /// `Cx` the host is dispatching through lives inside it. From a widget
    /// handler use `WindowHandle.close`, which only makes the request.
    pub fn closeWindowById(self: *Self, id: WindowId) void {
        // Assertions: validate input
        std.debug.assert(id.isValid());
        std.debug.assert(self.initialized);

        if (self.lookupWindow(id)) |window| {
            if (!window.isClosed()) window.close();
        }

        self.drainClosedWindows();
    }

    /// Close a window using its typed handle.
    pub fn closeWindow(self: *Self, comptime State: type, handle: WindowHandle(State)) void {
        self.closeWindowById(handle.getId());
    }

    /// Reclaim every window whose host close sequence has finished.
    ///
    /// `isClosed()` is the single signal all three close routes share — the
    /// user clicking the OS close button, `WindowHandle.close`, and
    /// `closeWindowById` — so polling it is what makes them converge on one
    /// teardown path instead of each needing its own. It is derived state read
    /// straight from the window, never a flag this module could let drift.
    ///
    /// Teardown is deliberately *not* done from the close callback itself: on
    /// AppKit that callback runs inside `windowShouldClose:`, with the NSWindow
    /// still on the host's stack, and on every backend it can run inside the
    /// window's own input dispatch. Both make destroying the window there a
    /// use-after-free. Draining separates the decision from the destruction.
    ///
    /// Reached from `openWindow`, `closeWindowById`, `deinit`, and — while the
    /// app is running — once per host event-loop turn via the hook `run`
    /// installs. The last of those is what covers closes the app never asked
    /// for: the titlebar button and the compositor only set `isClosed()`, so
    /// without a per-turn drain such a window kept its context and its slot
    /// until the app happened to call one of the other three.
    ///
    /// Precondition: as `closeWindowById`. Idempotent and bounded; safe to call
    /// when nothing is pending.
    pub fn drainClosedWindows(self: *Self) void {
        std.debug.assert(self.initialized);

        const destroyed = self.reclaimClosedWindows();
        std.debug.assert(destroyed <= MAX_WINDOWS);

        if (destroyed > 0) self.checkQuitCondition();
    }

    /// Reclaim closed windows and report how many were destroyed.
    ///
    /// Split from `drainClosedWindows` so `openWindow` can reclaim slots
    /// without the quit check that would fire between closing the last window
    /// and opening its replacement.
    fn reclaimClosedWindows(self: *Self) u32 {
        std.debug.assert(self.initialized);
        std.debug.assert(self.open_window_count <= MAX_WINDOWS);

        var destroyed: u32 = 0;
        var index: u32 = self.open_window_count;

        // Descending, because `removeWindowSlot` swap-removes: the entry that
        // moves down into `index` always comes from above, which this walk has
        // already visited. Every live entry is therefore examined exactly once,
        // which is what bounds the loop at `open_window_count` iterations.
        while (index > 0) {
            index -= 1;
            std.debug.assert(index < self.open_window_count);

            const id = self.open_window_ids[index];
            const window = self.lookupWindow(id) orelse {
                // The registry no longer holds it, so something outside `App`
                // destroyed it. The context is unreachable now, but dropping
                // the slot at least stops the id leaking toward `MAX_WINDOWS`.
                self.removeWindowSlot(index);
                destroyed += 1;
                continue;
            };

            if (!window.isClosed()) continue;

            self.destroyWindowSlot(index);
            destroyed += 1;
        }

        std.debug.assert(destroyed <= MAX_WINDOWS);
        std.debug.assert(self.open_window_count <= MAX_WINDOWS);
        return destroyed;
    }

    /// Destroy every window this app opened, closed or not.
    ///
    /// Only reached from `deinit`, where the event loop has already stopped, so
    /// there is no dispatch to be re-entering.
    fn closeAllWindows(self: *Self) void {
        std.debug.assert(self.initialized);
        std.debug.assert(self.open_window_count <= MAX_WINDOWS);

        // Always drop the *last* slot: a swap-remove of the last entry
        // relocates nothing, so no entry is visited twice. Each iteration
        // decrements `open_window_count`, which bounds the loop.
        while (self.open_window_count > 0) {
            self.destroyWindowSlot(self.open_window_count - 1);
        }

        std.debug.assert(self.open_window_count == 0);
    }

    // =========================================================================
    // Teardown list bookkeeping
    // =========================================================================

    /// Record a platform-assigned id and its context teardown thunk.
    fn trackWindow(self: *Self, id: WindowId, teardown: ContextTeardownFn) void {
        std.debug.assert(id.isValid());
        std.debug.assert(self.open_window_count < MAX_WINDOWS);

        self.open_window_ids[self.open_window_count] = id;
        self.open_window_teardowns[self.open_window_count] = teardown;
        self.open_window_count += 1;

        std.debug.assert(self.open_window_count <= MAX_WINDOWS);
        std.debug.assert(self.open_window_teardowns[self.open_window_count - 1] != null);
    }

    /// Drop an id from the teardown list without destroying anything.
    ///
    /// Only the `openWindow` unwind path needs this: there the context and the
    /// platform window are torn down by their own `errdefer`s, so the slot must
    /// be released *without* a second teardown. A miss is a no-op.
    fn untrackWindowId(self: *Self, id: WindowId) void {
        std.debug.assert(id.isValid());
        std.debug.assert(self.open_window_count <= MAX_WINDOWS);

        const index = self.findWindowSlot(id) orelse return;
        self.removeWindowSlot(index);

        std.debug.assert(self.findWindowSlot(id) == null);
    }

    /// Tear down the window in slot `index`: context, platform window, slot.
    fn destroyWindowSlot(self: *Self, index: u32) void {
        std.debug.assert(index < self.open_window_count);
        std.debug.assert(self.open_window_ids[index].isValid());

        const id = self.open_window_ids[index];

        // Context first: it owns the framework `Window`, whose teardown still
        // walks this platform window's atlases. Then the platform window, which
        // unregisters itself from the platform and self-destroys — which is why
        // `App` must not unregister first and strand the pointer it still needs.
        if (self.lookupWindow(id)) |window| {
            if (self.open_window_teardowns[index]) |teardown| teardown(window);
            window.deinit();

            // Pair-assert across the boundary: the window withdrew itself, so
            // `windowCount()` has now decremented.
            std.debug.assert(self.platform.getWindow(id) == null);
        }

        self.removeWindowSlot(index);

        std.debug.assert(self.findWindowSlot(id) == null);
    }

    /// Index of `id` in the teardown list, or null.
    fn findWindowSlot(self: *const Self, id: WindowId) ?u32 {
        std.debug.assert(id.isValid());
        std.debug.assert(self.open_window_count <= MAX_WINDOWS);

        var index: u32 = 0;
        while (index < self.open_window_count) : (index += 1) {
            if (self.open_window_ids[index] == id) return index;
        }
        return null;
    }

    /// Release slot `index` from both parallel arrays.
    fn removeWindowSlot(self: *Self, index: u32) void {
        std.debug.assert(index < self.open_window_count);
        std.debug.assert(self.open_window_count <= MAX_WINDOWS);

        // Swap-remove: order carries no meaning, and keeping the live entries
        // dense is what bounds every scan over the table. The vacated tail is
        // reset rather than left stale so a later read cannot resurrect a dead
        // id or call a thunk against a window that no longer exists.
        const last = self.open_window_count - 1;
        self.open_window_ids[index] = self.open_window_ids[last];
        self.open_window_teardowns[index] = self.open_window_teardowns[last];
        self.open_window_ids[last] = .invalid;
        self.open_window_teardowns[last] = null;
        self.open_window_count = last;

        std.debug.assert(self.open_window_count < MAX_WINDOWS);
        std.debug.assert(self.open_window_teardowns[last] == null);
    }

    /// Resolve a platform-assigned id to the concrete window type.
    ///
    /// The platform boundary deals only in `*anyopaque`, so the cast lives in
    /// this one helper instead of being repeated — and, previously,
    /// inconsistently validated — at each call site.
    fn lookupWindow(self: *const Self, id: WindowId) ?*PlatformWindow {
        std.debug.assert(id.isValid());
        std.debug.assert(self.initialized);

        const window_ptr = self.platform.getWindow(id) orelse return null;
        const window: *PlatformWindow = @ptrCast(@alignCast(window_ptr));
        std.debug.assert(window.getWindowId() == id);
        return window;
    }

    // =========================================================================
    // Window Queries
    // =========================================================================

    /// Get the number of open windows.
    pub fn windowCount(self: *const Self) u32 {
        return self.platform.windowCount();
    }

    /// Get the currently focused window ID.
    pub fn activeWindow(self: *const Self) ?WindowId {
        return self.platform.getActiveWindowId();
    }

    /// Focus tracking follows the platform, so this also accepts `null`.
    pub fn setActiveWindow(self: *Self, id: ?WindowId) void {
        if (id) |window_id| std.debug.assert(window_id.isValid());
        if (id) |window_id| std.debug.assert(self.platform.getWindow(window_id) != null);
        self.platform.setActiveWindowId(id);
    }

    /// Check if a window is still open.
    ///
    /// Registration alone is not enough: a window stays registered until the
    /// teardown drain reaches it, which is strictly after its close sequence
    /// completed. Reporting `true` for a window the user can no longer see is
    /// the exact confusion this second test removes; `WindowHandle.isValid`
    /// answers the same question the same way.
    pub fn isWindowOpen(self: *const Self, id: WindowId) bool {
        if (!id.isValid()) return false;

        const window = self.lookupWindow(id) orelse return false;
        std.debug.assert(window.getWindowId() == id);
        return !window.isClosed();
    }

    /// Get the platform (for `WindowHandle` operations).
    ///
    /// `WindowHandle` resolves ids against the platform registry because that
    /// is where window identity lives; there is no app-side registry to hand out.
    pub fn getPlatform(self: *Self) *Platform {
        std.debug.assert(self.initialized);
        return &self.platform;
    }

    /// Get the platform (const, for read-only `WindowHandle` operations).
    pub fn getPlatformConst(self: *const Self) *const Platform {
        std.debug.assert(self.initialized);
        return &self.platform;
    }

    // =========================================================================
    // Event Loop
    // =========================================================================

    /// Run the application event loop.
    ///
    /// Blocks until `quit()` is called or, if `quit_policy` says so, until the
    /// last window closes.
    ///
    /// The per-turn hook installed here is what makes a host-initiated close —
    /// the titlebar button, a compositor request, the window menu — reclaim its
    /// `WindowContext`. Those routes only mark the window `isClosed()`; before
    /// the hook existed nothing polled that flag until the app happened to call
    /// `openWindow`, `closeWindowById`, or `deinit`, so an app that does not
    /// quit on its last window leaked a full context per open/close cycle and
    /// walked the slot table toward `MAX_WINDOWS`.
    pub fn run(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.initialized);
        std.debug.assert(self.platform.windowCount() > 0); // Need at least one window

        self.platform.setLoopTurnCallback(loopTurn);
        self.running = true;

        self.platform.run();

        // A `host_callback` backend returns from `run` with the host still
        // scheduled to call back, so the hook must stay armed and the windows
        // must stay live (`runner.ownsTeardownAfterRun` draws the same line).
        // A `blocking_event_loop` backend has stopped, so this frame owns what
        // the final turn left behind: reclaim it, then disarm so nothing can
        // re-enter `App` between here and `deinit`.
        if (!self.platform.isRunning()) {
            self.platform.setLoopTurnCallback(null);
            self.drainClosedWindows();

            // The loop has stopped, so the app is no longer running however it
            // was stopped. `quit()` clears this itself, but the host can also
            // stop the loop without it — `Cx.quit` goes straight to
            // `Platform.quit` because a `Cx` cannot reach its `App` — and that
            // left `isRunning()` reporting true for the rest of the process.
            self.running = false;
        }
    }

    /// Signal the application to quit.
    ///
    /// Stops the event loop. Does not close windows - call `deinit()` for cleanup.
    pub fn quit(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.initialized);

        self.running = false;
        self.platform.quit();
    }

    /// Check if the app is currently running.
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// Create a WindowContext with shared resources.
    /// Uses the App's shared text system and atlases for consistent rendering.
    fn createWindowContext(
        self: *Self,
        comptime State: type,
        window: *PlatformWindow,
        state: *State,
        comptime render: fn (*Cx) void,
    ) !*WindowContext(State) {
        // Assertions: validate inputs
        std.debug.assert(@intFromPtr(window) != 0);
        std.debug.assert(@intFromPtr(state) != 0);

        const WinCtx = WindowContext(State);

        // Shared-resources mode: all windows share one text system and atlas
        // set, fixing font glitching where layout and rendering used different
        // atlases. `&self.resources` is lent as a borrowed view (each window's
        // own `resources` is `owned = false`), and `&self.context_app` lets
        // every window borrow the same `EntityMap` for cross-window observation.
        const ctx = try WinCtx.initWithSharedResources(
            self.allocator,
            window,
            state,
            render,
            &self.resources,
            &self.context_app,
            self.io,
        );

        // Wire up shared atlases to window for rendering
        // Now layout and rendering use the SAME atlas, eliminating glitching
        window.setTextAtlas(self.resources.text_system.getAtlas());
        window.setSvgAtlas(self.resources.svg_atlas.getAtlas());
        window.setImageAtlas(self.resources.image_atlas.getAtlas());

        // Set root state on this window's Window instance (not globally)
        // This enables multi-window support where each window has its own state
        ctx.window.setRootState(State, state);

        return ctx;
    }

    /// Stop the application if the configured policy says the last window
    /// closing should end it.
    ///
    /// Split into two branches rather than one `and`: whether the policy quits
    /// at all and whether any window remains are separate facts, and a failed
    /// assertion or a debugger stop should say which one decided (CLAUDE.md §6).
    fn checkQuitCondition(self: *Self) void {
        std.debug.assert(self.initialized);

        if (!self.quit_policy.quitsOnLastWindowClosed()) return;
        if (self.platform.windowCount() != 0) return;

        self.quit();
    }
};

// =============================================================================
// openWindow helpers
// =============================================================================

/// Translate app-level window options into the platform boundary struct.
///
/// Pure, so it lives outside `App` (CLAUDE.md §5: push computation downward).
/// `glass_style` is forwarded by value: there is one canonical `GlassStyle`
/// shared by every backend, so the previous `@enumFromInt(@intFromEnum(...))`
/// bridge — which silently produced the wrong style once the two enums' tag
/// orderings diverged — is gone.
fn windowOptionsFrom(options: *const AppWindowOptions) WindowOptions {
    std.debug.assert(options.width > 0);
    std.debug.assert(options.height > 0);
    std.debug.assert(options.background_opacity >= 0.0);
    std.debug.assert(options.background_opacity <= 1.0);

    return .{
        .title = options.title,
        .width = options.width,
        .height = options.height,
        .background_color = options.background_color orelse
            Color.rgba(0.95, 0.95, 0.95, 1.0),
        .min_size = options.min_size,
        .max_size = options.max_size,
        .centered = options.centered,
        .background_opacity = options.background_opacity,
        .glass_style = options.glass_style,
        .glass_corner_radius = options.glass_corner_radius,
        .titlebar_transparent = options.titlebar_transparent,
        .full_size_content = options.full_size_content,
        .custom_shaders = options.custom_shaders,
    };
}

/// Reclaim closed windows once per host event-loop turn.
///
/// Installed by `App.run` and called by the backend from the one point in its
/// cycle where no window callback is on the stack. That placement is the
/// precondition `drainClosedWindows` documents and cannot check: teardown frees
/// the `WindowContext` that owns the `Cx`, so draining from inside a window's
/// own dispatch — which is where every close route runs — would be a
/// use-after-free. See `platform/contract.zig`'s `LoopTurnCallback` note.
///
/// `App` is recovered by field offset rather than through a stored context
/// pointer because `App` owns `platform` by value and is documented as never
/// moving after `initInPlace`, so the offset is exact and costs no storage
/// (CLAUDE.md §10 — don't take aliases). `App.run` is the only installer, so
/// the platform reached here is always an `App`'s own field.
fn loopTurn(plat: *Platform) void {
    std.debug.assert(@intFromPtr(plat) != 0);

    const app: *App = @fieldParentPtr("platform", plat);

    // Proves the recovery landed on a live `App` rather than some other
    // owner's platform: `initialized` is only ever set by `initInPlace`.
    std.debug.assert(app.initialized);
    std.debug.assert(&app.platform == plat);

    app.drainClosedWindows();
}

/// Build the platform close callback for a window of the given state type.
///
/// The callback only relays the user's veto. It cannot also tear the window
/// down: on AppKit it runs inside `windowShouldClose:`, before the NSWindow has
/// left the host's stack, and on every backend it can run inside the window's
/// own input dispatch, where the `Cx` being dispatched lives in the very
/// `WindowContext` teardown would free. Declining the veto marks the window
/// `isClosed()`, and `App.drainClosedWindows` reclaims it from a safe point.
fn closeCallback(comptime State: type) *const fn (*PlatformWindow) bool {
    return struct {
        fn onClose(w: *PlatformWindow) bool {
            const wctx = w.getUserData(WindowContext(State)) orelse return true;
            const user_close = wctx.on_close orelse return true;
            return user_close(&wctx.cx);
        }
    }.onClose;
}

/// Build the type-erased `WindowContext(State)` teardown for a window.
///
/// This is how a non-generic `App` frees a generic context without becoming
/// generic itself: `openWindow` knows `State`, so it instantiates the thunk
/// there and stores the resulting function pointer in the window's slot.
fn contextTeardown(comptime State: type) ContextTeardownFn {
    return struct {
        fn teardown(w: *PlatformWindow) void {
            std.debug.assert(@intFromPtr(w) != 0);

            const wctx = w.getUserData(WindowContext(State)) orelse return;

            // Clear the back-pointer before freeing. `PlatformWindow.deinit`
            // runs immediately after this and must not be able to hand a
            // dangling context to a late callback.
            w.setUserData(null);
            wctx.deinit();

            std.debug.assert(w.getUserData(WindowContext(State)) == null);
        }
    }.teardown;
}

// =============================================================================
// AppWindowOptions
// =============================================================================

/// Options for opening a new window via App.openWindow().
pub const AppWindowOptions = struct {
    /// Window title
    title: []const u8 = "Window",

    /// Initial window width (logical pixels)
    width: f64 = DEFAULT_WIDTH,

    /// Initial window height (logical pixels)
    height: f64 = DEFAULT_HEIGHT,

    /// Background color (null for default)
    background_color: ?Color = null,

    /// Minimum window size
    min_size: ?geometry.Size(f64) = null,

    /// Maximum window size
    max_size: ?geometry.Size(f64) = null,

    /// Center window on screen
    centered: bool = true,

    // Callbacks

    /// Input event handler
    on_event: ?*const fn (*Cx, InputEvent) bool = null,

    /// Close request handler (return false to prevent close)
    on_close: ?*const fn (*Cx) bool = null,

    /// Resize handler
    on_resize: ?*const fn (*Cx, f64, f64) void = null,

    // Glass/transparency (macOS)

    // Widths match `interface.WindowOptions` exactly so forwarding is a copy,
    // not a lossy conversion.

    /// Background opacity (0.0 = transparent, 1.0 = opaque)
    background_opacity: f64 = 1.0,

    /// Glass blur style
    glass_style: GlassStyle = .none,

    /// Corner radius for glass effect
    glass_corner_radius: f64 = 16.0,

    /// Make titlebar transparent
    titlebar_transparent: bool = false,

    /// Extend content under titlebar
    full_size_content: bool = false,

    // Advanced

    /// Custom shaders
    custom_shaders: []const shader_mod.CustomShader = &.{},
};

// =============================================================================
// Tests
// =============================================================================

test "App type instantiation" {
    // Just verify the type compiles correctly
    _ = App;
    _ = AppWindowOptions;
}

test "AppWindowOptions defaults" {
    const opts = AppWindowOptions{};

    std.debug.assert(opts.width == DEFAULT_WIDTH);
    std.debug.assert(opts.height == DEFAULT_HEIGHT);
    std.debug.assert(opts.centered == true);
    std.debug.assert(opts.background_opacity == 1.0);
}

test "MAX_WINDOWS matches the platform registry bound" {
    // The app must not admit a window the platform registry would reject, so
    // the two bounds are pinned equal rather than merely "reasonable".
    try std.testing.expectEqual(WindowRegistry.MAX_WINDOWS, MAX_WINDOWS);
    std.debug.assert(MAX_WINDOWS >= 1);
    std.debug.assert(MAX_WINDOWS <= 256);
}

test "AppWindowOptions forwards to WindowOptions without conversion" {
    // Goal: catch a re-widening of the app-level option fields. Forwarding in
    // `windowOptionsFrom` is a plain copy only while the types match exactly;
    // a mismatch would reintroduce a lossy cast at the boundary.
    const app_fields = @typeInfo(AppWindowOptions).@"struct".fields;
    const platform_fields = @typeInfo(WindowOptions).@"struct".fields;

    inline for (.{ "background_opacity", "glass_style", "glass_corner_radius" }) |name| {
        const app_type = @FieldType(AppWindowOptions, name);
        const platform_type = @FieldType(WindowOptions, name);
        try std.testing.expectEqual(platform_type, app_type);
    }

    std.debug.assert(app_fields.len > 0);
    std.debug.assert(platform_fields.len > 0);
}

test "windowOptionsFrom preserves the canonical glass style" {
    // Positive and negative space: a non-default style must survive the hop
    // (the old cross-enum cast remapped it), and the default must stay `.none`.
    const glass = AppWindowOptions{ .glass_style = .glass_regular };
    try std.testing.expectEqual(GlassStyle.glass_regular, windowOptionsFrom(&glass).glass_style);

    const plain = AppWindowOptions{};
    try std.testing.expectEqual(GlassStyle.none, windowOptionsFrom(&plain).glass_style);

    // A null background color resolves to the app default, not transparent.
    try std.testing.expectEqual(@as(f32, 1.0), windowOptionsFrom(&plain).background_color.a);
}

// -----------------------------------------------------------------------------
// Teardown slot table
//
// The slot table is pure bookkeeping over ids the platform minted: `trackWindow`,
// `findWindowSlot`, `removeWindowSlot`, and `untrackWindowId` never touch
// `platform`, `resources`, or `context_app`. That is what lets the leak-bound be
// tested on every target without standing up a host, which is the property the
// close-path regression turned on: before this change a closed window kept its
// slot forever and an app walked up to `MAX_WINDOWS` and then refused to open
// anything.
// -----------------------------------------------------------------------------

/// Initialize only the slot-table fields of an otherwise `undefined` `App`.
fn initSlotTableOnly(app: *App) void {
    app.open_window_ids = @splat(.invalid);
    app.open_window_teardowns = @splat(null);
    app.open_window_count = 0;
    app.initialized = true;
}

/// Stand-in teardown thunk: the table stores the pointer, it never calls it.
fn testTeardown(_: *PlatformWindow) void {}

/// Every slot must be back to its unused encoding.
fn expectSlotTableEmpty(app: *const App) !void {
    try std.testing.expectEqual(@as(u32, 0), app.open_window_count);
    for (app.open_window_ids) |id| try std.testing.expect(!id.isValid());
    for (app.open_window_teardowns) |teardown| try std.testing.expect(teardown == null);
}

test "slot table fills to capacity and drains without leaking an entry" {
    // Capacity test per CLAUDE.md §24: fill exactly, verify the last valid
    // insert, then release everything and verify the documented empty state.
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    initSlotTableOnly(app);

    var raw: u32 = 1;
    while (raw <= MAX_WINDOWS) : (raw += 1) {
        app.trackWindow(WindowId.fromRaw(raw), testTeardown);
        try std.testing.expectEqual(raw, app.open_window_count);
    }
    try std.testing.expectEqual(MAX_WINDOWS, app.open_window_count);

    // The last insert is addressable, and every live slot carries its thunk.
    try std.testing.expect(app.findWindowSlot(WindowId.fromRaw(MAX_WINDOWS)) != null);
    for (app.open_window_teardowns) |teardown| try std.testing.expect(teardown != null);

    raw = 1;
    while (raw <= MAX_WINDOWS) : (raw += 1) {
        app.untrackWindowId(WindowId.fromRaw(raw));
        try std.testing.expectEqual(MAX_WINDOWS - raw, app.open_window_count);
        try std.testing.expect(app.findWindowSlot(WindowId.fromRaw(raw)) == null);
    }

    try expectSlotTableEmpty(app);
}

test "slot table swap-remove keeps surviving entries addressable" {
    // Removing from the middle is the case a naive shift-free compaction gets
    // wrong: the tail entry moves down, and must still be findable afterwards.
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    initSlotTableOnly(app);

    const first = WindowId.fromRaw(7);
    const middle = WindowId.fromRaw(8);
    const last = WindowId.fromRaw(9);

    app.trackWindow(first, testTeardown);
    app.trackWindow(middle, testTeardown);
    app.trackWindow(last, testTeardown);

    app.untrackWindowId(middle);

    try std.testing.expectEqual(@as(u32, 2), app.open_window_count);
    try std.testing.expect(app.findWindowSlot(middle) == null);
    try std.testing.expect(app.findWindowSlot(first) != null);
    try std.testing.expect(app.findWindowSlot(last) != null);

    // Both live slots must still hold a thunk after the swap.
    try std.testing.expect(app.open_window_teardowns[0] != null);
    try std.testing.expect(app.open_window_teardowns[1] != null);

    app.untrackWindowId(first);
    app.untrackWindowId(last);
    try expectSlotTableEmpty(app);
}

test "repeated open/close cycles do not walk the slot table toward capacity" {
    // The regression this guards: `WindowHandle.close` tore nothing down, so
    // every open/close pair consumed a slot permanently. Cycle far past
    // `MAX_WINDOWS` with fresh ids and require the table to stay bounded.
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    initSlotTableOnly(app);

    const cycle_count: u32 = MAX_WINDOWS * 4;
    var raw: u32 = 1;
    while (raw <= cycle_count) : (raw += 1) {
        const id = WindowId.fromRaw(raw);
        app.trackWindow(id, testTeardown);
        try std.testing.expectEqual(@as(u32, 1), app.open_window_count);
        app.untrackWindowId(id);
        try std.testing.expectEqual(@as(u32, 0), app.open_window_count);
    }

    try expectSlotTableEmpty(app);
}

test "QuitPolicy resolves the two explicit policies on every target" {
    // These two arms are the point of the enum: an author who wants a specific
    // behaviour gets it regardless of what the host platform's convention is.
    try std.testing.expect(QuitPolicy.last_window_closed.quitsOnLastWindowClosed());
    try std.testing.expect(!QuitPolicy.explicit.quitsOnLastWindowClosed());
}

test "QuitPolicy.platform_default follows the host convention" {
    // Goal: pin the convention itself, not just that it compiles. macOS
    // applications outlive their windows; everywhere else they exit. This is
    // the one place `platform_default` is interpreted, so if the expression
    // ever inverts, this is what catches it.
    //
    // Asserted against `builtin.os.tag` directly rather than reusing
    // `platform.is_macos`, so the test cannot agree with a broken constant by
    // construction.
    const on_macos = @import("builtin").os.tag == .macos;
    const quits = QuitPolicy.platform_default.quitsOnLastWindowClosed();

    if (on_macos) {
        try std.testing.expect(!quits);
    } else {
        try std.testing.expect(quits);
    }

    // Positive and negative space (CLAUDE.md §11): `platform_default` must
    // resolve to exactly one of the explicit policies, never to something else.
    const matches_explicit = quits == QuitPolicy.last_window_closed.quitsOnLastWindowClosed();
    const matches_never = quits == QuitPolicy.explicit.quitsOnLastWindowClosed();
    try std.testing.expect(matches_explicit or matches_never);
}

test "a fresh App defaults to the platform convention" {
    // The default is the whole behaviour change: `initInPlace` used to set an
    // unconditional "quit on last window", so this guards against a regression
    // to a hardcoded policy. Only the policy field is exercised — a full
    // `initInPlace` needs a host connection.
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);

    app.quit_policy = .platform_default;
    try std.testing.expectEqual(QuitPolicy.platform_default, app.quit_policy);
    try std.testing.expectEqual(
        !platform.is_macos,
        app.quit_policy.quitsOnLastWindowClosed(),
    );
}

test "untracking an id the table never held is a no-op" {
    // Negative space: `openWindow`'s unwind path and a drain can both report
    // the same window, so a miss must not corrupt the count.
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    initSlotTableOnly(app);

    app.untrackWindowId(WindowId.fromRaw(1));
    try expectSlotTableEmpty(app);

    app.trackWindow(WindowId.fromRaw(2), testTeardown);
    app.untrackWindowId(WindowId.fromRaw(3));
    try std.testing.expectEqual(@as(u32, 1), app.open_window_count);

    app.untrackWindowId(WindowId.fromRaw(2));
    try expectSlotTableEmpty(app);
}
