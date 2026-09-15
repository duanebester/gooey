//! Fixed-capacity headless backend satisfying the production platform contract.
//!
//! `TestBackend` exists so shared runtime code can be driven without AppKit,
//! Wayland, or a browser, and so the compile-time platform contract has a
//! target-neutral witness. It is deliberately *not* a convenient mock: a mock
//! with unbounded storage and infallible calls would let runtime code pass
//! tests while violating the two rules that matter most on a real host —
//! static allocation (`CLAUDE.md` §2) and a hard bound on everything (§4).
//!
//! What this backend models, and why each property is worth the code:
//!
//! - **Every resource is a fixed inline array.** No `ArrayList`, no
//!   `AutoHashMap`, no allocator call outside `Platform.initInPlace`. Window
//!   storage comes from a slot pool owned by the `Platform`, so
//!   `PlatformWindow.init` can ignore its `Allocator` parameter entirely.
//!   "No allocation after initialization" is therefore observable here rather
//!   than merely asserted.
//! - **Explicit lifecycle state.** `Lifecycle` is the allocation/lifecycle
//!   guard described in `docs/platform_interface_design.md`; every contract
//!   entry point asserts it, and every recorded call is stamped with it, which
//!   is how shutdown-ordering tests observe "quit after deinit began".
//! - **Deterministic sequence numbers.** One monotonic counter stamps calls,
//!   frames, and events, so ordering is assertable without timing.
//! - **Configurable failure at every fallible boundary.** `FailurePlan` drives
//!   platform-init failure, window-init failure before and *after* registration
//!   (the partial-initialization cleanup path), and failure of the nth
//!   `registerWindow`.
//! - **Bounded, fail-fast recording.** Call, frame, and event logs have fixed
//!   capacity and panic with resource name, capacity, and requested index when
//!   exhausted. They never wrap and never silently drop, because a dropped
//!   record turns an assertion about interaction into a false negative.
//!
//! ## Usage
//!
//! ```zig
//! const TestBackend = @import("gooey").testing.TestBackend;
//!
//! var plat: TestBackend.Platform = undefined;
//! try plat.initInPlace(std.testing.allocator);
//! defer plat.deinit();
//!
//! const options = TestBackend.WindowOptions{ .width = 320, .height = 200 };
//! const win = try TestBackend.PlatformWindow.init(std.testing.allocator, &plat, &options);
//! defer win.deinit();
//!
//! plat.run(); // Records, marks running, and returns: there is no host loop.
//! ```
//!
//! ## Target neutrality
//!
//! `src/testing/mod.zig` is reachable from the root module on every target, so
//! this file imports only target-neutral modules: the shared platform
//! interface and contract, geometry, scene, text, and input. Importing a
//! concrete backend here would break the wasm build.

const std = @import("std");

const geometry = @import("../core/geometry.zig");
const scene_mod = @import("../scene/mod.zig");
const text_mod = @import("../text/mod.zig");
const input = @import("../input/mod.zig");
const interface = @import("../platform/interface.zig");
const contract = @import("../platform/contract.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const WindowId = interface.WindowId;
const WindowOptions = interface.WindowOptions;
const CursorShape = interface.CursorShape;
const DriveModel = interface.DriveModel;
const PlatformCapabilities = interface.PlatformCapabilities;

// =============================================================================
// Backend namespace
// =============================================================================

/// The headless backend namespace, shaped exactly like `platform/macos/mod.zig`.
///
/// `platform/mod.zig` and `contract.zig` bind to `Platform`, `PlatformWindow`,
/// and `drive_model`; everything else below is a convenience spelling so test
/// code can write `TestBackend.WindowOptions` without a second import.
pub const TestBackend = struct {
    pub const Platform = TestPlatform;
    pub const PlatformWindow = TestWindow;

    /// A blocking event loop is the model shared runtime code exercises least
    /// safely, so the headless backend claims it on purpose: choosing
    /// `.host_callback` would leave `run`-blocking call paths untested. `run`
    /// still returns immediately — see `TestPlatform.run` for why that is
    /// honest rather than a cheat.
    pub const drive_model: DriveModel = .blocking_event_loop;

    pub const capabilities = TestPlatform.capabilities;

    pub const WindowOptions = interface.WindowOptions;
    pub const CursorShape = interface.CursorShape;
    pub const GlassStyle = interface.GlassStyle;
};

// Pin the backend to the compile-time contract. Kept at file scope rather than
// inside `TestBackend` so the verifier runs while `TestBackend`'s own
// declarations are already resolved, avoiding a comptime dependency loop.
comptime {
    contract.verifyBackend(TestBackend);
}

// =============================================================================
// Capacities
// =============================================================================
//
// Every bound below is named with its unit and is small on purpose: a capacity
// test must be able to fill the resource *exactly* and then attempt one more
// operation, and a 4096-entry log makes that test slow rather than thorough.

/// Window slots in the platform's pool, and therefore registry entries.
pub const window_count_max: u32 = 8;

/// Resident input events awaiting dispatch.
pub const event_count_max: u32 = 64;

/// Events dispatched by a single `drainEvents` call. Bounds per-frame work
/// independently of queue depth so a full queue cannot become a latency spike.
pub const event_count_frame_max: u32 = 16;

/// Recorded frame submissions (`setScene` calls).
pub const frame_record_count_max: u32 = 32;

/// Recorded contract calls.
pub const call_count_max: u32 = 256;

/// Bytes of window title storage, excluding any terminator.
pub const title_bytes_max: u32 = 64;

/// Bytes of IME marked/inserted text storage.
pub const ime_bytes_max: u32 = 64;

/// Largest accepted window edge in logical pixels. One past this is rejected by
/// `TestWindow.init` as an operating error, not an assertion, so the
/// one-past-maximum case is testable.
pub const framebuffer_dimension_max: u32 = 16_384;

comptime {
    // Relationships between capacities are load-bearing and cheap to check.
    assert(event_count_frame_max <= event_count_max);
    assert(frame_record_count_max <= call_count_max);
    assert(window_count_max <= interface.WindowRegistry.MAX_WINDOWS);
    assert(title_bytes_max > 0);
    assert(ime_bytes_max > 0);
    assert(window_count_max > 0);
}

// =============================================================================
// Errors
// =============================================================================

/// Every operating error this backend can report.
pub const Error = error{
    /// `FailurePlan.fail_platform_init` was set.
    PlatformInitFailed,
    /// `FailurePlan.fail_window_init` or `fail_window_init_after_register`.
    WindowInitFailed,
    /// `FailurePlan.fail_on_nth_register` matched this registration.
    WindowRegisterFailed,
    /// All `window_count_max` slots are occupied.
    WindowSlotsExhausted,
    /// A requested window edge exceeded `framebuffer_dimension_max`.
    WindowTooLarge,
    /// All `event_count_max` event slots are occupied.
    EventQueueFull,
};

// =============================================================================
// Lifecycle
// =============================================================================

/// Allocation and lifecycle guard.
///
/// The initialization boundary is the transition `initializing -> running`.
/// Allocator use is permitted only in `initializing`; every other phase must
/// operate out of storage reserved before the boundary.
pub const Lifecycle = enum(u8) {
    uninitialized,
    initializing,
    running,
    deinitializing,
    deinitialized,

    /// Whether contract calls other than `initInPlace` may run.
    pub fn accepts_calls(self: Lifecycle) bool {
        if (self == .running) return true;
        if (self == .deinitializing) return true;
        return false;
    }
};

// =============================================================================
// Failure injection
// =============================================================================

/// Which fallible boundaries should fail.
///
/// `Platform.initInPlace`'s signature is pinned by the contract and cannot take
/// extra parameters, so platform-init failure is armed through the module-level
/// `pending_failure_plan`. Everything else is read from `Platform.failure_plan`,
/// which tests may edit directly after init.
pub const FailurePlan = struct {
    /// `initInPlace` returns `error.PlatformInitFailed`.
    fail_platform_init: bool = false,

    /// `TestWindow.init` fails before claiming a slot.
    fail_window_init: bool = false,

    /// `TestWindow.init` fails *after* claiming a slot and registering, which
    /// is the partial-initialization cleanup path.
    fail_window_init_after_register: bool = false,

    /// The nth (1-based) `registerWindow` call fails.
    fail_on_nth_register: ?u32 = null,
};

/// Plan copied into the next `Platform.initInPlace`.
var pending_failure_plan: FailurePlan = .{};

/// Arm the plan consulted by the next `Platform.initInPlace`.
///
/// Tests must pair this with `clearPendingFailurePlan`, because module-level
/// state outlives a single test.
pub fn setPendingFailurePlan(plan: FailurePlan) void {
    pending_failure_plan = plan;
}

/// Reset the pending plan to "nothing fails".
pub fn clearPendingFailurePlan() void {
    pending_failure_plan = .{};
}

// =============================================================================
// Records
// =============================================================================

/// Contract entry points worth recording.
pub const CallTag = enum(u8) {
    platform_init,
    platform_deinit,
    platform_run,
    platform_quit,
    register_window,
    unregister_window,
    window_init,
    window_deinit,
    set_title,
    set_background_color,
    set_appearance,
    set_cursor_shape,
    request_render,
    focus,
    close,
    set_scene,
    set_text_atlas,
    set_svg_atlas,
    set_image_atlas,
    set_marked_text,
    clear_marked_text,
    set_inserted_text,
    set_ime_cursor_rect,
    dispatch_input,
    resize,
};

/// One recorded contract call.
///
/// `detail` carries the single salient argument, encoded per tag so the record
/// stays a fixed 24 bytes instead of a tagged union over every argument list:
///
/// | Tag                               | `detail`                        |
/// | --------------------------------- | ------------------------------- |
/// | `register_window`                 | assigned raw `WindowId`         |
/// | `unregister_window`               | removed raw `WindowId`          |
/// | `window_init`, `window_deinit`    | slot index                      |
/// | `set_title`                       | copied byte count               |
/// | `set_marked_text`                 | copied byte count               |
/// | `set_inserted_text`               | copied byte count               |
/// | `set_appearance`                  | 1 for dark, 0 for light         |
/// | `set_cursor_shape`                | `@intFromEnum(CursorShape)`     |
/// | `request_render`, `focus`         | call count after this call      |
/// | `dispatch_input`                  | `@intFromEnum` of the event tag |
/// | `resize`                          | new width truncated to integer  |
/// | anything else                     | 0                               |
pub const CallRecord = struct {
    /// Monotonic stamp shared with frame and event records.
    sequence: u64 = 0,
    tag: CallTag = .platform_init,
    /// Lifecycle phase observed *during* the call.
    lifecycle: Lifecycle = .uninitialized,
    window_id: WindowId = .invalid,
    detail: u64 = 0,
};

/// One recorded frame handoff.
pub const FrameRecord = struct {
    sequence: u64 = 0,
    window_id: WindowId = .invalid,
    scene: ?*const scene_mod.Scene = null,
};

// =============================================================================
// Fixed window registry
// =============================================================================

/// Fixed-capacity replacement for `interface.WindowRegistry`.
///
/// The shared `WindowRegistry` stores windows in an `AutoHashMap`, so `put`
/// may allocate on *any* registration, not just during initialization. Using
/// it here would make "this backend never allocates after init" untestable,
/// which is the single property the headless backend exists to prove. This
/// registry therefore reimplements the same observable semantics — monotonic
/// ids, registration that does *not* elect an active window, and unregistering
/// the active window clearing it — over `window_count_max` inline slots.
pub const FixedWindowRegistry = struct {
    slots: [window_count_max]Slot,
    occupied_count: u32,
    next_raw_id: u32,
    active: ?WindowId,

    /// One registry entry. `window == null` means free.
    pub const Slot = struct {
        id: WindowId = .invalid,
        window: ?*anyopaque = null,
    };

    const Self = @This();

    /// Establish every field. No allocation: the slots are inline.
    pub fn initInPlace(self: *Self) void {
        @memset(&self.slots, .{});
        self.occupied_count = 0;
        self.next_raw_id = 1;
        self.active = null;

        assert(self.occupied_count == 0);
        assert(self.next_raw_id == 1);
    }

    /// Assign the next id to `window_ptr`.
    pub fn register(self: *Self, window_ptr: *anyopaque) Error!WindowId {
        assert(@intFromPtr(window_ptr) != 0);
        assert(self.occupied_count <= window_count_max);
        assert(self.next_raw_id >= 1);

        if (self.occupied_count == window_count_max) return error.WindowSlotsExhausted;

        const index = self.findFreeSlot() orelse return error.WindowSlotsExhausted;
        assert(self.slots[index].window == null);

        const id: WindowId = WindowId.fromRaw(self.next_raw_id);
        assert(id.isValid());

        self.next_raw_id += 1;
        if (self.next_raw_id == 0) self.next_raw_id = 1;

        self.slots[index] = .{ .id = id, .window = window_ptr };
        self.occupied_count += 1;

        // Registration deliberately does not elect an active window, matching
        // `interface.WindowRegistry.register`. The implicit "first window
        // wins" election was removed there because it made focus policy an
        // invisible side effect of registration; keeping it here would make
        // this backend the one place that still disagrees.

        assert(self.occupied_count <= window_count_max);
        assert(self.contains(id));
        return id;
    }

    /// Remove `id`, zeroing its slot. Returns the stored pointer if present.
    pub fn unregister(self: *Self, id: WindowId) ?*anyopaque {
        assert(id.isValid());
        assert(self.occupied_count <= window_count_max);

        const index = self.findSlot(id) orelse return null;
        const removed = self.slots[index].window;
        assert(removed != null);

        // Zero the slot rather than only clearing `window`, so a later
        // occupant cannot observe the previous id (`CLAUDE.md` §21).
        self.slots[index] = .{};
        assert(self.occupied_count >= 1);
        self.occupied_count -= 1;

        if (self.active) |active_id| {
            if (active_id == id) self.active = null;
        }

        assert(!self.contains(id));
        return removed;
    }

    pub fn get(self: *const Self, id: WindowId) ?*anyopaque {
        if (!id.isValid()) return null;
        const index = self.findSlot(id) orelse return null;
        assert(index < window_count_max);
        return self.slots[index].window;
    }

    pub fn contains(self: *const Self, id: WindowId) bool {
        if (!id.isValid()) return false;
        return self.findSlot(id) != null;
    }

    pub fn count(self: *const Self) u32 {
        assert(self.occupied_count <= window_count_max);
        return self.occupied_count;
    }

    pub fn setActive(self: *Self, id: ?WindowId) void {
        if (id) |window_id| {
            assert(window_id.isValid());
            assert(self.contains(window_id));
        }
        self.active = id;
    }

    pub fn getActive(self: *const Self) ?WindowId {
        if (self.active) |id| assert(id.isValid());
        return self.active;
    }

    /// Bounded linear scan. `window_count_max` is 8, so an index would cost
    /// more storage and invariants than it saves.
    fn findSlot(self: *const Self, id: WindowId) ?u32 {
        assert(id.isValid());
        for (&self.slots, 0..) |*slot, index| {
            assert(index < window_count_max);
            if (slot.window == null) continue;
            if (slot.id == id) return @intCast(index);
        }
        return null;
    }

    fn findFreeSlot(self: *const Self) ?u32 {
        for (&self.slots, 0..) |*slot, index| {
            assert(index < window_count_max);
            if (slot.window == null) return @intCast(index);
        }
        return null;
    }
};

// =============================================================================
// Platform
// =============================================================================

/// Headless platform: window slot pool, bounded logs, and lifecycle guard.
pub const TestPlatform = struct {
    lifecycle: Lifecycle,
    /// Backing `isRunning`. Separate from `lifecycle` because the host loop
    /// being armed and the platform being past its init boundary are different
    /// facts, and conflating them made `quit` untestable during shutdown.
    host_running: bool,
    allocator: Allocator,
    failure_plan: FailurePlan,
    registry: FixedWindowRegistry,
    window_slots: [window_count_max]WindowSlot,
    calls: [call_count_max]CallRecord,
    call_count: u32,
    frames: [frame_record_count_max]FrameRecord,
    frame_count: u32,
    events: [event_count_max]input.InputEvent,
    event_count: u32,
    /// Monotonic stamp source shared by every log.
    sequence_next: u64,
    /// Counts `registerWindow` entries, including the ones that fail, so
    /// `FailurePlan.fail_on_nth_register` is unambiguous.
    register_call_count: u32,

    /// One window slot. `occupied` tracks the pool, not the registry, so a
    /// leaked slot is distinguishable from a leaked registration.
    pub const WindowSlot = struct {
        window: TestWindow = undefined,
        occupied: bool = false,
    };

    pub const capabilities = PlatformCapabilities{
        .high_dpi = true,
        .multi_window = true,
        // Nothing here touches a GPU, a display link, or a clipboard, and
        // claiming otherwise would let a capability-gated code path go
        // untested on the one backend that could test it cheaply.
        .gpu_accelerated = false,
        .display_link = false,
        .can_close_window = true,
        .glass_effects = false,
        .clipboard = false,
        .file_dialogs = false,
        .ime = true,
        .custom_cursors = true,
        .window_drag_by_content = false,
        .name = "test-headless",
        .graphics_backend = "none",
    };

    const Self = @This();

    comptime {
        // Sized so a test can hold one on the stack on native targets while
        // staying clear of the 1 MiB wasm stack (`CLAUDE.md` §14).
        assert(@sizeOf(Self) <= 128 * 1024);
    }

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Establish every field in place.
    ///
    /// `noinline` per `CLAUDE.md` §14: this writes several kilobytes of inline
    /// arrays and must not have its frame folded into a caller.
    pub noinline fn initInPlace(self: *Self, allocator: Allocator) Error!void {
        self.lifecycle = .initializing;
        self.failure_plan = pending_failure_plan;

        if (self.failure_plan.fail_platform_init) {
            // Nothing has been acquired yet, so there is nothing to unwind.
            // Return the lifecycle to `uninitialized` so a failed platform can
            // never be mistaken for a live one.
            self.lifecycle = .uninitialized;
            return error.PlatformInitFailed;
        }

        self.host_running = false;
        self.allocator = allocator;
        self.registry.initInPlace();

        @memset(&self.window_slots, .{});
        @memset(&self.calls, .{});
        @memset(&self.frames, .{});

        self.call_count = 0;
        self.frame_count = 0;
        self.event_count = 0;
        self.sequence_next = 1;
        self.register_call_count = 0;

        assert(self.registry.count() == 0);
        assert(self.registry.getActive() == null);

        self.lifecycle = .running;
        self.recordCall(.platform_init, .invalid, 0);

        // The log was empty a moment ago, so exactly one record means
        // `recordCall` appended rather than overwrote, and its stamped
        // lifecycle proves the transition happened before the record.
        assert(self.call_count == 1);
        assert(self.calls[0].lifecycle == .running);
    }

    /// Release the slot pool and stop accepting calls.
    ///
    /// The logs are deliberately left readable: shutdown-ordering assertions
    /// need them, and leaving `self.* = undefined` would make "quit after
    /// deinit began" unobservable.
    pub fn deinit(self: *Self) void {
        assert(self.lifecycle == .running);
        assert(self.call_count <= call_count_max);

        self.lifecycle = .deinitializing;
        self.recordCall(.platform_deinit, .invalid, 0);

        // Stopping the host loop is part of teardown, and recording it while
        // the lifecycle reads `deinitializing` is what makes the ordering
        // assertable.
        self.quit();

        var released: u32 = 0;
        for (0..window_count_max) |index| {
            const slot_index: u32 = @intCast(index);
            if (!self.window_slots[slot_index].occupied) continue;
            self.releaseWindowSlot(slot_index);
            released += 1;
        }
        assert(released <= window_count_max);

        self.event_count = 0;
        self.host_running = false;
        self.lifecycle = .deinitialized;

        // The pool must be empty, or a slot has leaked past shutdown. Every
        // still-registered window held a slot, so the surviving registrations
        // cannot outnumber the slots just released.
        assert(self.occupiedWindowSlotCount() == 0);
        assert(self.registry.count() <= released);
    }

    /// Mark the host loop armed and return.
    ///
    /// A production `blocking_event_loop` backend blocks here in `[NSApp run]`
    /// or `wl_display_dispatch`. A headless backend has no host loop to pump,
    /// and inventing a blocking spin would hang every test. Tests drive work
    /// explicitly instead: `pushEvent` + `drainEvents` for input, and
    /// `TestWindow.setScene` for frames.
    pub fn run(self: *Self) void {
        assert(self.lifecycle == .running);
        assert(!self.host_running);

        self.host_running = true;
        self.recordCall(.platform_run, .invalid, 0);
    }

    /// Stop the host loop. Valid before `run`, during `run`, and once
    /// `deinit` has begun; all three are states a real host can reach.
    pub fn quit(self: *Self) void {
        const live = self.lifecycle.accepts_calls();
        assert(live);
        assert(self.call_count <= call_count_max);

        self.host_running = false;
        self.recordCall(.platform_quit, .invalid, 0);
    }

    pub fn isRunning(self: *const Self) bool {
        assert(self.lifecycle != .uninitialized);
        assert(self.lifecycle != .initializing);
        return self.host_running;
    }

    // =========================================================================
    // Registry
    // =========================================================================

    pub fn registerWindow(self: *Self, window: *anyopaque) Error!WindowId {
        assert(@intFromPtr(window) != 0);
        const live = self.lifecycle.accepts_calls();
        assert(live);

        self.register_call_count += 1;
        if (self.failure_plan.fail_on_nth_register) |nth| {
            assert(nth >= 1);
            if (nth == self.register_call_count) return error.WindowRegisterFailed;
        }

        const id = try self.registry.register(window);
        assert(id.isValid());

        self.recordCall(.register_window, id, id.raw());
        return id;
    }

    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        assert(id.isValid());
        const live = self.lifecycle.accepts_calls();
        assert(live);

        const removed = self.registry.unregister(id);
        _ = removed;

        self.recordCall(.unregister_window, id, id.raw());
        assert(!self.registry.contains(id));
    }

    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        assert(self.lifecycle != .uninitialized);
        assert(self.lifecycle != .initializing);
        return self.registry.get(id);
    }

    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        assert(self.lifecycle != .uninitialized);
        assert(self.lifecycle != .initializing);
        return self.registry.getActive();
    }

    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        const live = self.lifecycle.accepts_calls();
        assert(live);

        self.registry.setActive(id);

        // The real invariant is that an active id always names a *registered*
        // window: a stale active id would let input and frames be routed to a
        // released slot.
        if (self.registry.getActive()) |active| assert(self.registry.contains(active));
    }

    pub fn windowCount(self: *const Self) u32 {
        assert(self.lifecycle != .uninitialized);
        assert(self.registry.count() <= window_count_max);
        return self.registry.count();
    }

    // =========================================================================
    // Window slot pool
    // =========================================================================

    /// Claim a free window slot. The returned index is stable for the slot's
    /// lifetime, which is what lets `TestWindow` live at a fixed address.
    pub fn claimWindowSlot(self: *Self) Error!u32 {
        const live = self.lifecycle.accepts_calls();
        assert(live);

        for (0..window_count_max) |index| {
            const slot_index: u32 = @intCast(index);
            if (self.window_slots[slot_index].occupied) continue;

            self.window_slots[slot_index].occupied = true;
            zeroWindowStorage(&self.window_slots[slot_index].window);

            // A freshly claimed slot must carry no previous occupant's
            // identity, or a stale `getWindow` could resolve to it.
            assert(self.window_slots[slot_index].window.window_id == .invalid);
            return slot_index;
        }
        return error.WindowSlotsExhausted;
    }

    /// Return a slot to the pool, zeroing its byte buffers so a later occupant
    /// cannot read stale text (`CLAUDE.md` §21).
    pub fn releaseWindowSlot(self: *Self, slot_index: u32) void {
        assert(slot_index < window_count_max);
        assert(self.window_slots[slot_index].occupied);

        zeroWindowStorage(&self.window_slots[slot_index].window);
        self.window_slots[slot_index].occupied = false;

        // The released slot must hold no readable text, which is the property
        // `zeroWindowStorage` exists for (`CLAUDE.md` §21).
        assert(self.window_slots[slot_index].window.title_len == 0);
        assert(self.window_slots[slot_index].window.title_buffer[title_bytes_max - 1] == 0);
    }

    /// Count of occupied pool slots, which a leak test compares against
    /// `windowCount`.
    pub fn occupiedWindowSlotCount(self: *const Self) u32 {
        var occupied: u32 = 0;
        for (&self.window_slots) |*slot| {
            if (slot.occupied) occupied += 1;
        }
        assert(occupied <= window_count_max);
        return occupied;
    }

    // =========================================================================
    // Recording
    // =========================================================================

    /// Whether `recordCall` can accept another entry.
    ///
    /// Exposed because exhausting the log panics by design, and a test cannot
    /// `expectError` a panic. Capacity tests assert this predicate flips at
    /// exactly `call_count_max` instead of triggering the panic.
    pub fn callLogHasRoom(self: *const Self) bool {
        assert(self.call_count <= call_count_max);
        return self.call_count < call_count_max;
    }

    /// Whether `recordFrame` can accept another entry. Same rationale as
    /// `callLogHasRoom`.
    pub fn frameLogHasRoom(self: *const Self) bool {
        assert(self.frame_count <= frame_record_count_max);
        return self.frame_count < frame_record_count_max;
    }

    /// Append a call record, or fail fast.
    ///
    /// Exhaustion is a capacity-planning error in the *test*, so it panics with
    /// the resource name, configured capacity, and requested index rather than
    /// wrapping or dropping. A dropped record would turn an interaction
    /// assertion into a silent false negative.
    pub fn recordCall(self: *Self, tag: CallTag, window_id: WindowId, detail: u64) void {
        assert(self.call_count <= call_count_max);

        if (self.call_count < call_count_max) {
            const index = self.call_count;
            self.calls[index] = .{
                .sequence = self.nextSequence(),
                .tag = tag,
                .lifecycle = self.lifecycle,
                .window_id = window_id,
                .detail = detail,
            };
            self.call_count = index + 1;

            assert(self.call_count <= call_count_max);
            assert(self.calls[index].sequence >= 1);
            return;
        }

        std.debug.panic(
            "TestBackend recording exhausted: resource='TestPlatform.calls' " ++
                "capacity={d} requested_index={d} tag={s}",
            .{ call_count_max, self.call_count, @tagName(tag) },
        );
    }

    /// Append a frame record, or fail fast. See `recordCall`.
    pub fn recordFrame(self: *Self, window_id: WindowId, scene: *const scene_mod.Scene) void {
        assert(window_id.isValid());
        assert(self.frame_count <= frame_record_count_max);

        if (self.frame_count < frame_record_count_max) {
            const index = self.frame_count;
            self.frames[index] = .{
                .sequence = self.nextSequence(),
                .window_id = window_id,
                .scene = scene,
            };
            self.frame_count = index + 1;

            assert(self.frame_count <= frame_record_count_max);
            assert(self.frames[index].scene != null);
            return;
        }

        std.debug.panic(
            "TestBackend recording exhausted: resource='TestPlatform.frames' " ++
                "capacity={d} requested_index={d} window_id={d}",
            .{ frame_record_count_max, self.frame_count, window_id.raw() },
        );
    }

    /// Next monotonic stamp. Never returns 0, so a zeroed record is
    /// distinguishable from a real one.
    fn nextSequence(self: *Self) u64 {
        assert(self.sequence_next >= 1);
        const sequence = self.sequence_next;
        self.sequence_next += 1;
        assert(self.sequence_next > sequence);
        return sequence;
    }

    /// Index of the first record with `tag`, or null.
    pub fn findCall(self: *const Self, tag: CallTag) ?u32 {
        assert(self.call_count <= call_count_max);
        for (self.calls[0..self.call_count], 0..) |record, index| {
            if (record.tag == tag) return @intCast(index);
        }
        return null;
    }

    /// Number of recorded calls with `tag`.
    pub fn countCalls(self: *const Self, tag: CallTag) u32 {
        assert(self.call_count <= call_count_max);
        var total: u32 = 0;
        for (self.calls[0..self.call_count]) |record| {
            if (record.tag == tag) total += 1;
        }
        assert(total <= self.call_count);
        return total;
    }

    // =========================================================================
    // Event queue
    // =========================================================================

    /// Enqueue an event for later dispatch.
    ///
    /// Queued events are copied by value, so any text a variant references
    /// (`KeyEvent.characters`, `TextInputEvent.text`) is *borrowed*; the caller
    /// must keep it alive until the event is drained. This matches how a real
    /// backend hands the host's transient buffers to Gooey.
    pub fn pushEvent(self: *Self, event: input.InputEvent) Error!void {
        const live = self.lifecycle.accepts_calls();
        assert(live);
        assert(self.event_count <= event_count_max);

        if (self.event_count == event_count_max) return error.EventQueueFull;

        self.events[self.event_count] = event;
        self.event_count += 1;

        assert(self.event_count <= event_count_max);
    }

    /// Dispatch up to `event_count_frame_max` queued events to `window`.
    ///
    /// Returns the number dispatched. Bounding the batch separately from the
    /// queue depth is the difference between a bounded queue and unbounded
    /// latency (`CLAUDE.md` §4).
    pub fn drainEvents(self: *Self, window: *TestWindow) u32 {
        const live = self.lifecycle.accepts_calls();
        assert(live);
        assert(self.event_count <= event_count_max);

        const queued_before = self.event_count;
        const batch = @min(self.event_count, event_count_frame_max);
        assert(batch <= event_count_frame_max);
        assert(batch <= queued_before);

        for (0..batch) |index| {
            const event = self.events[index];
            self.recordCall(.dispatch_input, window.window_id, eventTagDetail(event));
            if (window.input_callback) |callback| {
                _ = callback(window, event);
            }
        }

        // Compact the remainder forward; the queue is a bounded array, not a
        // ring, so ordering stays trivially assertable.
        const remaining = self.event_count - batch;
        for (0..remaining) |index| {
            self.events[index] = self.events[index + batch];
        }
        self.event_count = remaining;

        // Conservation: nothing may be dropped or duplicated by the compaction
        // above. A bounded batch must bound latency, not lose work.
        assert(batch + remaining == queued_before);
        assert(self.event_count <= event_count_max);

        if (window.post_input_callback) |callback| callback(window);
        return batch;
    }
};

/// Zero a window slot's storage between occupants.
///
/// Only the byte buffers and scalar state are reset; the struct is not
/// `@memset` wholesale because that would write zeros into the non-optional
/// `platform: *TestPlatform` field, and reading a null non-optional pointer is
/// undefined behaviour even if nothing dereferences it.
fn zeroWindowStorage(window: *TestWindow) void {
    @memset(&window.title_buffer, 0);
    @memset(&window.marked_buffer, 0);
    @memset(&window.inserted_buffer, 0);

    window.slot_index = 0;
    window.window_id = .invalid;
    window.title_len = 0;
    window.marked_len = 0;
    window.inserted_len = 0;
    window.closed = false;
    window.render_request_count = 0;
    window.focus_count = 0;
    window.scene = null;
    window.text_atlas = null;
    window.svg_atlas = null;
    window.image_atlas = null;
    window.user_data = null;
    window.input_callback = null;
    window.render_callback = null;
    window.close_callback = null;
    window.resize_callback = null;
    window.post_input_callback = null;

    // Check the *last* byte of each buffer, not the first: these assertions
    // exist to catch a future edit that zeroes only a prefix (`buffer[0..len]`)
    // and so leaves a previous occupant's tail readable (`CLAUDE.md` §21).
    assert(window.title_buffer[title_bytes_max - 1] == 0);
    assert(window.marked_buffer[ime_bytes_max - 1] == 0);
    assert(window.inserted_buffer[ime_bytes_max - 1] == 0);
}

/// Encode an event's union tag as a record detail.
fn eventTagDetail(event: input.InputEvent) u64 {
    return @intFromEnum(std.meta.activeTag(event));
}

// =============================================================================
// Window
// =============================================================================

/// Headless window living in a `TestPlatform` slot.
///
/// Every getter reports what was actually set rather than a canned value, so a
/// test that asserts on `getSize` or `hasMarkedText` is asserting on the
/// backend's real state.
pub const TestWindow = struct {
    platform: *TestPlatform,
    slot_index: u32,
    window_id: WindowId,

    size: geometry.Size(f64),
    scale_factor: f64,
    background_color: geometry.Color,
    clear_color: geometry.Color,
    dark_appearance: bool,
    cursor_shape: CursorShape,

    mouse_position: geometry.Point(f64),
    mouse_inside: bool,
    closed: bool,
    render_request_count: u32,
    focus_count: u32,

    title_len: u32,
    title_buffer: [title_bytes_max]u8,
    marked_len: u32,
    marked_buffer: [ime_bytes_max]u8,
    inserted_len: u32,
    inserted_buffer: [ime_bytes_max]u8,
    ime_cursor_rect: [4]f32,

    scene: ?*const scene_mod.Scene,
    text_atlas: ?*const text_mod.Atlas,
    svg_atlas: ?*const text_mod.Atlas,
    image_atlas: ?*const text_mod.Atlas,

    user_data: ?*anyopaque,
    input_callback: ?InputCallback,
    render_callback: ?RenderCallback,
    close_callback: ?CloseCallback,
    resize_callback: ?ResizeCallback,
    post_input_callback: ?PostInputCallback,

    pub const InputCallback = *const fn (*TestWindow, input.InputEvent) bool;
    pub const RenderCallback = *const fn (*TestWindow) void;
    pub const CloseCallback = *const fn (*TestWindow) bool;
    pub const ResizeCallback = *const fn (*TestWindow, f64, f64) void;
    pub const PostInputCallback = *const fn (*TestWindow) void;

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Claim a slot, register it, and initialize it.
    ///
    /// `allocator` is deliberately unused: storage comes from the platform's
    /// fixed pool. That is what makes "no allocation after `initInPlace`" an
    /// observable property of this backend instead of a comment.
    pub fn init(
        allocator: Allocator,
        plat: *TestPlatform,
        options: *const WindowOptions,
    ) Error!*Self {
        _ = allocator;

        const live = plat.lifecycle.accepts_calls();
        assert(live);
        assert(options.width >= 0);
        assert(options.height >= 0);

        if (plat.failure_plan.fail_window_init) return error.WindowInitFailed;
        if (options.width > @as(f64, framebuffer_dimension_max)) return error.WindowTooLarge;
        if (options.height > @as(f64, framebuffer_dimension_max)) return error.WindowTooLarge;

        const count_before = plat.windowCount();

        const slot_index = try plat.claimWindowSlot();
        errdefer plat.releaseWindowSlot(slot_index);

        const self = &plat.window_slots[slot_index].window;

        const id = try plat.registerWindow(@ptrCast(self));
        errdefer plat.unregisterWindow(id);

        // The injected failure sits here on purpose: both a pool slot and a
        // registry entry are held, so unwinding must restore both.
        if (plat.failure_plan.fail_window_init_after_register) return error.WindowInitFailed;

        self.initFields(plat, slot_index, id, options);

        // A newly created window claims focus, exactly as every production
        // backend does at the end of its own `Window.init`. `contract.zig`
        // verifies signatures, not behaviour, so without this line
        // `getActiveWindowId()` returned null on the test backend and non-null
        // on all three production backends for the same program.
        plat.setActiveWindowId(id);
        plat.recordCall(.window_init, id, slot_index);

        assert(plat.windowCount() == count_before + 1);
        assert(plat.getActiveWindowId().? == id);
        return self;
    }

    /// Establish every field of a freshly claimed slot.
    fn initFields(
        self: *Self,
        plat: *TestPlatform,
        slot_index: u32,
        id: WindowId,
        options: *const WindowOptions,
    ) void {
        assert(slot_index < window_count_max);
        assert(id.isValid());

        self.platform = plat;
        self.slot_index = slot_index;
        self.window_id = id;

        self.size = .{ .width = options.width, .height = options.height };
        self.scale_factor = 1.0;
        self.background_color = options.background_color;
        self.clear_color = options.clearColor();
        self.dark_appearance = false;
        self.cursor_shape = .default;

        self.mouse_position = .{ .x = 0, .y = 0 };
        self.mouse_inside = false;
        self.closed = false;
        self.render_request_count = 0;
        self.focus_count = 0;

        self.ime_cursor_rect = .{ 0, 0, 0, 0 };
        self.scene = null;
        self.text_atlas = null;
        self.svg_atlas = null;
        self.image_atlas = null;

        self.user_data = null;
        self.input_callback = null;
        self.render_callback = null;
        self.close_callback = null;
        self.resize_callback = null;
        self.post_input_callback = null;

        // `claimWindowSlot` already zeroed the buffers; restate the lengths so
        // every field is established by this function.
        self.title_len = 0;
        self.marked_len = 0;
        self.inserted_len = 0;

        self.setTitle(options.title);

        assert(self.window_id == id);
        assert(self.slot_index == slot_index);
    }

    /// Unregister and return the slot to the pool.
    pub fn deinit(self: *Self) void {
        assert(self.window_id.isValid());
        assert(self.slot_index < window_count_max);

        const plat = self.platform;
        const slot_index = self.slot_index;
        const id = self.window_id;
        assert(plat.window_slots[slot_index].occupied);

        plat.recordCall(.window_deinit, id, slot_index);
        plat.unregisterWindow(id);
        plat.releaseWindowSlot(slot_index);

        assert(!plat.window_slots[slot_index].occupied);
        assert(plat.getWindow(id) == null);
    }

    // =========================================================================
    // Identity and geometry
    // =========================================================================

    pub fn getWindowId(self: *const Self) WindowId {
        assert(self.window_id.isValid());
        return self.window_id;
    }

    pub fn width(self: *const Self) u32 {
        assert(self.size.width >= 0);
        assert(self.size.width <= @as(f64, framebuffer_dimension_max));
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        assert(self.size.height >= 0);
        assert(self.size.height <= @as(f64, framebuffer_dimension_max));
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        assert(self.size.width >= 0);
        assert(self.size.height >= 0);
        return self.size;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        assert(self.scale_factor > 0);
        return self.scale_factor;
    }

    // =========================================================================
    // Native properties
    // =========================================================================

    /// Copy `new_title` into the fixed title buffer.
    ///
    /// Over-long titles are a programmer error, so this asserts rather than
    /// truncating; `titleFits` is the predicate a caller (or test) uses to
    /// check the bound without tripping the assertion.
    pub fn setTitle(self: *Self, new_title: []const u8) void {
        assert(titleFits(new_title));
        assert(self.title_len <= title_bytes_max);

        @memcpy(self.title_buffer[0..new_title.len], new_title);
        // Zero the tail so no bytes of a previous, longer title bleed through
        // a `title_buffer` read (`CLAUDE.md` §21).
        @memset(self.title_buffer[new_title.len..], 0);
        self.title_len = @intCast(new_title.len);

        // Unless the title fills the buffer exactly, the tail must read zero,
        // or a shorter title would expose the previous, longer one.
        if (self.title_len < title_bytes_max) {
            assert(self.title_buffer[title_bytes_max - 1] == 0);
        }
        self.platform.recordCall(.set_title, self.window_id, self.title_len);
    }

    /// Whether `candidate` fits the fixed title buffer.
    pub fn titleFits(candidate: []const u8) bool {
        return candidate.len <= title_bytes_max;
    }

    /// The title actually stored.
    pub fn title(self: *const Self) []const u8 {
        assert(self.title_len <= title_bytes_max);
        return self.title_buffer[0..self.title_len];
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        assert(color.a >= 0.0);
        assert(color.a <= 1.0);

        self.background_color = color;
        self.platform.recordCall(.set_background_color, self.window_id, 0);
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        assert(self.window_id.isValid());
        self.dark_appearance = dark;
        self.platform.recordCall(.set_appearance, self.window_id, @intFromBool(dark));
    }

    pub fn setCursorShape(self: *Self, shape: CursorShape) void {
        assert(self.window_id.isValid());
        assert(!self.closed);

        self.cursor_shape = shape;
        self.platform.recordCall(.set_cursor_shape, self.window_id, @intFromEnum(shape));
    }

    pub fn getClearColor(self: *const Self) geometry.Color {
        assert(self.clear_color.a >= 0.0);
        assert(self.clear_color.a <= 1.0);
        return self.clear_color;
    }

    // =========================================================================
    // Pointer state
    // =========================================================================

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        assert(self.window_id.isValid());
        return self.mouse_position;
    }

    pub fn isMouseInside(self: *const Self) bool {
        assert(self.window_id.isValid());
        return self.mouse_inside;
    }

    /// Test hook: move the pointer as a host would.
    pub fn setMousePosition(self: *Self, position: geometry.Point(f64), inside: bool) void {
        assert(self.window_id.isValid());

        // A pointer reported as inside must actually lie within the window's
        // logical bounds; hosts report out-of-bounds positions with
        // `inside = false` while a drag is tracked.
        if (inside) assert(position.x >= 0);
        if (inside) assert(position.x <= self.size.width);
        if (inside) assert(position.y >= 0);
        if (inside) assert(position.y <= self.size.height);

        self.mouse_position = position;
        self.mouse_inside = inside;
    }

    // =========================================================================
    // Host control
    // =========================================================================

    pub fn requestRender(self: *Self) void {
        assert(self.window_id.isValid());
        assert(self.render_request_count < std.math.maxInt(u32));

        self.render_request_count += 1;
        self.platform.recordCall(.request_render, self.window_id, self.render_request_count);
    }

    pub fn focus(self: *Self) void {
        assert(self.window_id.isValid());
        assert(!self.closed);

        self.focus_count += 1;
        self.platform.setActiveWindowId(self.window_id);
        self.platform.recordCall(.focus, self.window_id, self.focus_count);
    }

    pub fn close(self: *Self) void {
        assert(self.window_id.isValid());
        assert(self.slot_index < window_count_max);

        self.closed = true;
        self.platform.recordCall(.close, self.window_id, 0);

        // Closing is not destruction: the window stays registered and keeps
        // its slot until `deinit`, so a host close event cannot leave shared
        // code holding a pointer the registry has already forgotten.
        assert(self.platform.getWindow(self.window_id) != null);
        assert(self.platform.window_slots[self.slot_index].occupied);
    }

    pub fn isClosed(self: *const Self) bool {
        assert(self.window_id.isValid());
        return self.closed;
    }

    /// Test hook: deliver a host resize.
    pub fn resize(self: *Self, new_width: f64, new_height: f64) void {
        assert(new_width >= 0);
        assert(new_height >= 0);
        assert(new_width <= @as(f64, framebuffer_dimension_max));
        assert(new_height <= @as(f64, framebuffer_dimension_max));

        self.size = .{ .width = new_width, .height = new_height };
        self.platform.recordCall(.resize, self.window_id, @intFromFloat(new_width));
        if (self.resize_callback) |callback| callback(self, new_width, new_height);
    }

    /// Test hook: invoke the render callback as a display link would.
    pub fn tickRender(self: *Self) void {
        assert(self.window_id.isValid());
        assert(!self.closed);
        if (self.render_callback) |callback| callback(self);
    }

    /// Test hook: ask the close callback whether closing is permitted.
    pub fn requestClose(self: *Self) bool {
        assert(self.window_id.isValid());
        const permitted = if (self.close_callback) |callback| callback(self) else true;
        if (permitted) self.close();
        return permitted;
    }

    // =========================================================================
    // Frame handoff
    // =========================================================================

    pub fn setScene(self: *Self, new_scene: *const scene_mod.Scene) void {
        assert(self.window_id.isValid());
        assert(@intFromPtr(new_scene) != 0);

        self.scene = new_scene;
        self.platform.recordCall(.set_scene, self.window_id, 0);
        self.platform.recordFrame(self.window_id, new_scene);
    }

    pub fn setTextAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        assert(self.window_id.isValid());
        assert(@intFromPtr(atlas) != 0);

        self.text_atlas = atlas;
        self.platform.recordCall(.set_text_atlas, self.window_id, 0);
    }

    pub fn setSvgAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        assert(self.window_id.isValid());
        assert(@intFromPtr(atlas) != 0);

        self.svg_atlas = atlas;
        self.platform.recordCall(.set_svg_atlas, self.window_id, 0);
    }

    pub fn setImageAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        assert(self.window_id.isValid());
        assert(@intFromPtr(atlas) != 0);

        self.image_atlas = atlas;
        self.platform.recordCall(.set_image_atlas, self.window_id, 0);
    }

    // =========================================================================
    // IME bridge
    // =========================================================================

    pub fn setMarkedText(self: *Self, text: []const u8) void {
        assert(imeTextFits(text));
        assert(self.marked_len <= ime_bytes_max);

        @memcpy(self.marked_buffer[0..text.len], text);
        @memset(self.marked_buffer[text.len..], 0);
        self.marked_len = @intCast(text.len);

        // As in `setTitle`: a shorter composition must not leave the previous
        // one's tail readable.
        if (self.marked_len < ime_bytes_max) {
            assert(self.marked_buffer[ime_bytes_max - 1] == 0);
        }
        self.platform.recordCall(.set_marked_text, self.window_id, self.marked_len);
    }

    pub fn clearMarkedText(self: *Self) void {
        assert(self.window_id.isValid());
        assert(self.marked_len <= ime_bytes_max);

        @memset(&self.marked_buffer, 0);
        self.marked_len = 0;

        // Cancelling a composition must not disturb text already committed;
        // the two buffers are independent and were once the same one.
        assert(self.inserted_len <= ime_bytes_max);
        self.platform.recordCall(.clear_marked_text, self.window_id, 0);
    }

    pub fn setInsertedText(self: *Self, text: []const u8) void {
        assert(imeTextFits(text));
        assert(self.inserted_len <= ime_bytes_max);

        @memcpy(self.inserted_buffer[0..text.len], text);
        @memset(self.inserted_buffer[text.len..], 0);
        self.inserted_len = @intCast(text.len);

        if (self.inserted_len < ime_bytes_max) {
            assert(self.inserted_buffer[ime_bytes_max - 1] == 0);
        }
        self.platform.recordCall(.set_inserted_text, self.window_id, self.inserted_len);
    }

    pub fn hasMarkedText(self: *const Self) bool {
        assert(self.marked_len <= ime_bytes_max);
        return self.marked_len > 0;
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        assert(w >= 0);
        assert(h >= 0);

        self.ime_cursor_rect = .{ x, y, w, h };
        self.platform.recordCall(.set_ime_cursor_rect, self.window_id, 0);
    }

    /// Whether `candidate` fits the fixed IME buffers.
    pub fn imeTextFits(candidate: []const u8) bool {
        return candidate.len <= ime_bytes_max;
    }

    /// The marked text actually stored.
    pub fn markedText(self: *const Self) []const u8 {
        assert(self.marked_len <= ime_bytes_max);
        return self.marked_buffer[0..self.marked_len];
    }

    /// The inserted text actually stored.
    pub fn insertedText(self: *const Self) []const u8 {
        assert(self.inserted_len <= ime_bytes_max);
        return self.inserted_buffer[0..self.inserted_len];
    }

    // =========================================================================
    // Callbacks
    // =========================================================================

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        assert(self.window_id.isValid());
        self.input_callback = callback;
    }

    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        assert(self.window_id.isValid());
        self.render_callback = callback;
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        assert(self.window_id.isValid());
        self.close_callback = callback;
    }

    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        assert(self.window_id.isValid());
        self.resize_callback = callback;
    }

    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        assert(self.window_id.isValid());
        self.post_input_callback = callback;
    }

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        assert(self.window_id.isValid());
        self.user_data = data;
    }

    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        comptime assert(@sizeOf(T) > 0);
        comptime assert(@alignOf(T) > 0);

        if (self.user_data) |ptr| return @ptrCast(@alignCast(ptr));
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Shared fixture: an initialized platform with the failure plan cleared.
///
/// `pending_failure_plan` is module-level state that outlives a test, so every
/// test goes through here or clears it explicitly.
fn initPlatform(plat: *TestPlatform) !void {
    clearPendingFailurePlan();
    try plat.initInPlace(testing.allocator);
}

fn makeOptions(w: f64, h: f64) WindowOptions {
    return .{ .title = "t", .width = w, .height = h };
}

test "TestBackend satisfies the compile-time platform contract" {
    // The whole point of the backend: it is checked by the same verifier the
    // production macOS, Linux, and web backends are pinned with.
    comptime contract.verifyBackend(TestBackend);
    try testing.expectEqual(DriveModel.blocking_event_loop, TestBackend.drive_model);
}

test "platform init and deinit walk the lifecycle in order" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);

    try testing.expectEqual(Lifecycle.running, plat.lifecycle);
    try testing.expectEqual(@as(u32, 0), plat.windowCount());
    try testing.expect(!plat.isRunning());

    plat.deinit();
    try testing.expectEqual(Lifecycle.deinitialized, plat.lifecycle);
}

test "run marks the platform running without blocking" {
    // Goal: prove `run` returns. If it blocked, this test would hang rather
    // than fail, which is exactly why the headless backend must not pretend to
    // own a host loop.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    plat.run();
    try testing.expect(plat.isRunning());
    try testing.expect(plat.findCall(.platform_run) != null);
}

test "quit is valid before run, during run, and after deinit begins" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);

    plat.quit();
    try testing.expect(!plat.isRunning());
    const quit_before_run = plat.calls[plat.findCall(.platform_quit).?];
    try testing.expectEqual(Lifecycle.running, quit_before_run.lifecycle);

    plat.run();
    plat.quit();
    try testing.expect(!plat.isRunning());
    try testing.expectEqual(@as(u32, 2), plat.countCalls(.platform_quit));

    // `deinit` quits as part of teardown; the record's stamped lifecycle is
    // how "quit after shutdown began" becomes observable.
    plat.deinit();
    try testing.expectEqual(@as(u32, 3), plat.countCalls(.platform_quit));

    const last = plat.calls[plat.call_count - 1];
    try testing.expectEqual(CallTag.platform_quit, last.tag);
    try testing.expectEqual(Lifecycle.deinitializing, last.lifecycle);
}

test "platform init failure leaves the lifecycle uninitialized" {
    setPendingFailurePlan(.{ .fail_platform_init = true });
    defer clearPendingFailurePlan();

    var plat: TestPlatform = undefined;
    try testing.expectError(error.PlatformInitFailed, plat.initInPlace(testing.allocator));
    try testing.expectEqual(Lifecycle.uninitialized, plat.lifecycle);
}

test "window init and deinit round-trip through the registry and slot pool" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(320, 200);
    const win = try TestWindow.init(testing.allocator, &plat, &options);

    try testing.expectEqual(@as(u32, 1), plat.windowCount());
    try testing.expectEqual(@as(u32, 1), plat.occupiedWindowSlotCount());
    try testing.expectEqual(@as(u32, 320), win.width());
    try testing.expectEqual(@as(u32, 200), win.height());
    try testing.expectEqual(@as(f64, 1.0), win.getScaleFactor());
    try testing.expect(plat.getWindow(win.getWindowId()) != null);

    win.deinit();
    try testing.expectEqual(@as(u32, 0), plat.windowCount());
    try testing.expectEqual(@as(u32, 0), plat.occupiedWindowSlotCount());
}

test "window init failure before registration acquires nothing" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    plat.failure_plan.fail_window_init = true;

    const options = makeOptions(64, 64);
    try testing.expectError(
        error.WindowInitFailed,
        TestWindow.init(testing.allocator, &plat, &options),
    );
    try testing.expectEqual(@as(u32, 0), plat.windowCount());
    try testing.expectEqual(@as(u32, 0), plat.occupiedWindowSlotCount());
}

test "window init failure after registration unwinds both slot and registration" {
    // Goal: the partial-initialization cleanup path. Method: fail at the point
    // where a pool slot and a registry entry are both held, then assert the
    // registry count returns to its prior value and no slot leaks.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(64, 64);
    const keeper = try TestWindow.init(testing.allocator, &plat, &options);
    defer keeper.deinit();

    const count_before = plat.windowCount();
    const slots_before = plat.occupiedWindowSlotCount();
    try testing.expectEqual(@as(u32, 1), count_before);

    plat.failure_plan.fail_window_init_after_register = true;
    try testing.expectError(
        error.WindowInitFailed,
        TestWindow.init(testing.allocator, &plat, &options),
    );

    try testing.expectEqual(count_before, plat.windowCount());
    try testing.expectEqual(slots_before, plat.occupiedWindowSlotCount());
}

test "registerWindow failure on the nth call leaves no slot occupied" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    // The first window registers; the second registration is rejected, so
    // `TestWindow.init` must release the slot it had already claimed.
    plat.failure_plan.fail_on_nth_register = 2;

    const options = makeOptions(64, 64);
    const first = try TestWindow.init(testing.allocator, &plat, &options);
    defer first.deinit();

    try testing.expectError(
        error.WindowRegisterFailed,
        TestWindow.init(testing.allocator, &plat, &options),
    );
    try testing.expectEqual(@as(u32, 1), plat.windowCount());
    try testing.expectEqual(@as(u32, 1), plat.occupiedWindowSlotCount());
}

test "window slots fill exactly to capacity and reject one more" {
    // Capacity discipline: fill to exactly `window_count_max`, verify the last
    // valid init succeeds, then verify the documented failure mode.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(16, 16);
    var windows: [window_count_max]*TestWindow = undefined;

    for (0..window_count_max) |index| {
        windows[index] = try TestWindow.init(testing.allocator, &plat, &options);
        try testing.expectEqual(@as(u32, @intCast(index + 1)), plat.windowCount());
    }
    try testing.expectEqual(window_count_max, plat.windowCount());
    try testing.expect(windows[window_count_max - 1].getWindowId().isValid());

    try testing.expectError(
        error.WindowSlotsExhausted,
        TestWindow.init(testing.allocator, &plat, &options),
    );
    try testing.expectEqual(window_count_max, plat.windowCount());

    // One release makes exactly one more init succeed, and no more.
    windows[0].deinit();
    try testing.expectEqual(window_count_max - 1, plat.windowCount());
    const replacement = try TestWindow.init(testing.allocator, &plat, &options);
    try testing.expectError(
        error.WindowSlotsExhausted,
        TestWindow.init(testing.allocator, &plat, &options),
    );

    replacement.deinit();
    for (1..window_count_max) |index| windows[index].deinit();
}

test "released window slots are zeroed before reuse" {
    // Goal: no stale bytes bleed between occupants (CLAUDE.md §21). Method:
    // write a long title, release the slot, and inspect the pool storage
    // directly before anything re-initializes it.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(32, 32);
    const win = try TestWindow.init(testing.allocator, &plat, &options);

    const long_title = "x" ** title_bytes_max;
    win.setTitle(long_title);
    win.setMarkedText("composing");
    const slot_index = win.slot_index;
    try testing.expectEqual(@as(usize, title_bytes_max), win.title().len);

    win.deinit();

    const storage = &plat.window_slots[slot_index].window;
    try testing.expect(!plat.window_slots[slot_index].occupied);
    try testing.expectEqual(@as(u32, 0), storage.title_len);
    for (storage.title_buffer) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (storage.marked_buffer) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // Reusing the slot must observe a clean buffer, not the old title.
    const reused = try TestWindow.init(testing.allocator, &plat, &options);
    defer reused.deinit();
    try testing.expectEqual(slot_index, reused.slot_index);
    try testing.expectEqualStrings("t", reused.title());
    try testing.expect(!reused.hasMarkedText());
}

test "repeated claim and release of the same slot stays balanced" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(8, 8);
    var previous_id: WindowId = .invalid;

    for (0..16) |_| {
        const win = try TestWindow.init(testing.allocator, &plat, &options);
        // Ids are monotonic even though the slot is reused, so a stale id can
        // never resolve to the new occupant.
        try testing.expect(win.getWindowId() != previous_id);
        previous_id = win.getWindowId();

        try testing.expectEqual(@as(u32, 1), plat.occupiedWindowSlotCount());
        win.deinit();
        try testing.expectEqual(@as(u32, 0), plat.occupiedWindowSlotCount());
    }
}

test "registry tracks the active window like the production registry" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(64, 64);
    const first = try TestWindow.init(testing.allocator, &plat, &options);
    try testing.expectEqual(first.getWindowId(), plat.getActiveWindowId().?);

    const second = try TestWindow.init(testing.allocator, &plat, &options);
    try testing.expectEqual(second.getWindowId(), plat.getActiveWindowId().?);

    second.focus();
    try testing.expectEqual(second.getWindowId(), plat.getActiveWindowId().?);

    // Unregistering the active window clears it rather than leaving a dangling
    // id, which is the behaviour shared runtime code relies on.
    second.deinit();
    try testing.expect(plat.getActiveWindowId() == null);

    plat.setActiveWindowId(first.getWindowId());
    try testing.expectEqual(first.getWindowId(), plat.getActiveWindowId().?);
    plat.setActiveWindowId(null);
    try testing.expect(plat.getActiveWindowId() == null);

    first.deinit();
}

test "a new window claims focus and closing the active one clears it" {
    // Goal: pin the focus policy `contract.zig` cannot express. All three
    // production backends end `Window.init` with
    // `plat.setActiveWindowId(self.window_id)`, so a program that opens two
    // windows observes the *second* as active. This backend diverged —
    // `getActiveWindowId()` stayed null — until `TestWindow.init` published
    // focus too, and only a behavioural test can hold that in place.
    //
    // Method: create three windows checking the active id after each, then
    // destroy a non-active window and the active one, distinguishing "clears"
    // from "leaves a dangling id".
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    try testing.expect(plat.getActiveWindowId() == null);

    const options = makeOptions(64, 64);
    var windows: [3]*TestWindow = undefined;
    for (0..3) |index| {
        windows[index] = try TestWindow.init(testing.allocator, &plat, &options);
        try testing.expectEqual(windows[index].getWindowId(), plat.getActiveWindowId().?);
    }

    // Destroying a window that is not active must leave focus untouched.
    windows[0].deinit();
    try testing.expectEqual(windows[2].getWindowId(), plat.getActiveWindowId().?);

    // Destroying the active window clears focus. Note this is the shared
    // `WindowRegistry` policy that macOS and web inherit; Linux layers
    // `reelectActiveWindow` on top from its own `Window.deinit` because its
    // render pump paces from the active window alone. That re-election is a
    // platform detail above the boundary, so it is not modelled here.
    windows[2].deinit();
    try testing.expect(plat.getActiveWindowId() == null);

    // A surviving window can still be elected explicitly, proving the clear
    // did not corrupt the registry.
    plat.setActiveWindowId(windows[1].getWindowId());
    try testing.expectEqual(windows[1].getWindowId(), plat.getActiveWindowId().?);
    windows[1].deinit();
    try testing.expect(plat.getActiveWindowId() == null);
    try testing.expectEqual(@as(u32, 0), plat.occupiedWindowSlotCount());
}

test "getWindow rejects the invalid id and unknown ids" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    try testing.expect(plat.getWindow(.invalid) == null);
    try testing.expect(plat.getWindow(WindowId.fromRaw(999)) == null);
    try testing.expectEqual(@as(u32, 0), plat.windowCount());
}

test "window accepts the empty and maximum sizes and rejects one past maximum" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const empty_options = makeOptions(0, 0);
    const empty = try TestWindow.init(testing.allocator, &plat, &empty_options);
    try testing.expectEqual(@as(u32, 0), empty.width());
    try testing.expectEqual(@as(u32, 0), empty.height());
    empty.deinit();

    const max_dimension: f64 = @floatFromInt(framebuffer_dimension_max);
    const max_options = makeOptions(max_dimension, max_dimension);
    const largest = try TestWindow.init(testing.allocator, &plat, &max_options);
    try testing.expectEqual(framebuffer_dimension_max, largest.width());
    largest.deinit();

    const over_options = makeOptions(max_dimension + 1, max_dimension);
    try testing.expectError(
        error.WindowTooLarge,
        TestWindow.init(testing.allocator, &plat, &over_options),
    );
    const over_height = makeOptions(max_dimension, max_dimension + 1);
    try testing.expectError(
        error.WindowTooLarge,
        TestWindow.init(testing.allocator, &plat, &over_height),
    );
    try testing.expectEqual(@as(u32, 0), plat.occupiedWindowSlotCount());
}

test "setTitle stores exactly the bytes given and titleFits bounds the buffer" {
    // One-past-boundary on title length. An over-long title trips an assertion
    // by design, and a test cannot `expectError` a panic, so the boundary is
    // pinned on the `titleFits` predicate and the exactly-full copy.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(32, 32);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    try testing.expect(TestWindow.titleFits(""));
    try testing.expect(TestWindow.titleFits("x" ** title_bytes_max));
    try testing.expect(!TestWindow.titleFits("x" ** (title_bytes_max + 1)));

    win.setTitle("x" ** title_bytes_max);
    try testing.expectEqual(@as(usize, title_bytes_max), win.title().len);

    // A shorter title must not leave the previous title's tail readable.
    win.setTitle("ab");
    try testing.expectEqualStrings("ab", win.title());
    for (win.title_buffer[2..]) |byte| try testing.expectEqual(@as(u8, 0), byte);

    win.setTitle("");
    try testing.expectEqual(@as(usize, 0), win.title().len);
}

test "IME state reflects exactly what was set" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(32, 32);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    try testing.expect(!win.hasMarkedText());

    win.setMarkedText("nihongo");
    try testing.expect(win.hasMarkedText());
    try testing.expectEqualStrings("nihongo", win.markedText());

    win.setMarkedText("ni");
    try testing.expectEqualStrings("ni", win.markedText());
    for (win.marked_buffer[2..]) |byte| try testing.expectEqual(@as(u8, 0), byte);

    win.clearMarkedText();
    try testing.expect(!win.hasMarkedText());
    for (win.marked_buffer) |byte| try testing.expectEqual(@as(u8, 0), byte);

    win.setInsertedText("x" ** ime_bytes_max);
    try testing.expectEqual(@as(usize, ime_bytes_max), win.insertedText().len);
    try testing.expect(!TestWindow.imeTextFits("x" ** (ime_bytes_max + 1)));

    win.setImeCursorRect(1, 2, 3, 4);
    try testing.expectEqual(@as(f32, 3), win.ime_cursor_rect[2]);
}

test "window state getters report what was actually set" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = WindowOptions{
        .title = "glassy",
        .width = 100,
        .height = 50,
        .glass_style = .blur,
    };
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    // A glass style demands a transparent clear; the backend must not report
    // the opaque background color instead.
    try testing.expectEqual(@as(f32, 0.0), win.getClearColor().a);
    try testing.expectEqualStrings("glassy", win.title());

    try testing.expect(!win.isClosed());
    win.close();
    try testing.expect(win.isClosed());

    win.setMousePosition(.{ .x = 12, .y = 34 }, true);
    try testing.expectEqual(@as(f64, 12), win.getMousePosition().x);
    try testing.expect(win.isMouseInside());

    win.setAppearance(true);
    try testing.expect(win.dark_appearance);
    win.setBackgroundColor(geometry.Color.rgba(1, 0, 0, 1));
    try testing.expectEqual(@as(f32, 1.0), win.background_color.r);
}

test "resize updates the reported size and notifies the callback" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const Probe = struct {
        var last_width: f64 = 0;
        var last_height: f64 = 0;

        fn onResize(_: *TestWindow, w: f64, h: f64) void {
            last_width = w;
            last_height = h;
        }
    };
    Probe.last_width = 0;
    Probe.last_height = 0;

    const options = makeOptions(10, 10);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    win.setResizeCallback(Probe.onResize);
    win.resize(640, 480);

    try testing.expectEqual(@as(u32, 640), win.width());
    try testing.expectEqual(@as(f64, 480), win.getSize().height);
    try testing.expectEqual(@as(f64, 640), Probe.last_width);
    try testing.expectEqual(@as(f64, 480), Probe.last_height);
}

test "callbacks and user data round-trip, including clearing to null" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const Probe = struct {
        var input_count: u32 = 0;
        var render_count: u32 = 0;
        var post_count: u32 = 0;

        fn onInput(_: *TestWindow, _: input.InputEvent) bool {
            input_count += 1;
            return true;
        }
        fn onRender(_: *TestWindow) void {
            render_count += 1;
        }
        fn onPostInput(_: *TestWindow) void {
            post_count += 1;
        }
        fn refuseClose(_: *TestWindow) bool {
            return false;
        }
    };
    Probe.input_count = 0;
    Probe.render_count = 0;
    Probe.post_count = 0;

    const options = makeOptions(16, 16);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    var payload: u32 = 7;
    win.setUserData(&payload);
    try testing.expectEqual(@as(u32, 7), win.getUserData(u32).?.*);
    win.setUserData(null);
    try testing.expect(win.getUserData(u32) == null);

    win.setInputCallback(Probe.onInput);
    win.setRenderCallback(Probe.onRender);
    win.setPostInputCallback(Probe.onPostInput);
    win.setCloseCallback(Probe.refuseClose);

    win.tickRender();
    try testing.expectEqual(@as(u32, 1), Probe.render_count);

    // A close callback returning false must leave the window open.
    try testing.expect(!win.requestClose());
    try testing.expect(!win.isClosed());

    win.setRenderCallback(null);
    win.tickRender();
    try testing.expectEqual(@as(u32, 1), Probe.render_count);
}

test "event queue fills exactly to capacity and rejects one more" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const event: input.InputEvent = .{ .modifiers_changed = .{} };

    for (0..event_count_max) |index| {
        try plat.pushEvent(event);
        try testing.expectEqual(@as(u32, @intCast(index + 1)), plat.event_count);
    }
    try testing.expectEqual(event_count_max, plat.event_count);
    try testing.expectError(error.EventQueueFull, plat.pushEvent(event));
    try testing.expectEqual(event_count_max, plat.event_count);
}

test "drainEvents dispatches empty and maximum batches in order" {
    // Goal: per-frame work is bounded independently of queue depth, and
    // ordering is deterministic. Method: queue a full batch plus one, drain
    // twice, and check the dispatched tags against the queue order.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const Probe = struct {
        var seen: [event_count_frame_max * 2]u8 = undefined;
        var count: u32 = 0;

        fn onInput(_: *TestWindow, event: input.InputEvent) bool {
            seen[count] = @intFromEnum(std.meta.activeTag(event));
            count += 1;
            return true;
        }
    };
    Probe.count = 0;

    const options = makeOptions(16, 16);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();
    win.setInputCallback(Probe.onInput);

    // Empty batch first: no callback, no error.
    try testing.expectEqual(@as(u32, 0), plat.drainEvents(win));
    try testing.expectEqual(@as(u32, 0), Probe.count);

    const mouse: input.InputEvent = .{ .mouse_moved = .{
        .position = .{ .x = 0, .y = 0 },
        .button = .left,
        .click_count = 0,
        .modifiers = .{},
    } };
    const modifiers: input.InputEvent = .{ .modifiers_changed = .{} };

    for (0..event_count_frame_max) |_| try plat.pushEvent(mouse);
    try plat.pushEvent(modifiers);

    try testing.expectEqual(event_count_frame_max, plat.drainEvents(win));
    try testing.expectEqual(@as(u32, 1), plat.event_count);

    try testing.expectEqual(@as(u32, 1), plat.drainEvents(win));
    try testing.expectEqual(@as(u32, 0), plat.event_count);

    // The trailing modifier event must arrive last, not be reordered by the
    // compaction step.
    const mouse_tag: u8 = @intFromEnum(std.meta.activeTag(mouse));
    const modifiers_tag: u8 = @intFromEnum(std.meta.activeTag(modifiers));
    try testing.expectEqual(event_count_frame_max + 1, Probe.count);
    try testing.expectEqual(mouse_tag, Probe.seen[0]);
    try testing.expectEqual(modifiers_tag, Probe.seen[event_count_frame_max]);
}

test "recorded calls carry strictly increasing sequence numbers" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(16, 16);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    win.setCursorShape(.pointer);
    win.requestRender();
    win.setAppearance(true);

    try testing.expect(plat.call_count >= 4);
    var previous: u64 = 0;
    for (plat.calls[0..plat.call_count]) |record| {
        try testing.expect(record.sequence > previous);
        previous = record.sequence;
    }

    // Salient arguments are recorded, not just the fact of the call.
    const cursor_index = plat.findCall(.set_cursor_shape).?;
    try testing.expectEqual(
        @as(u64, @intFromEnum(CursorShape.pointer)),
        plat.calls[cursor_index].detail,
    );
    const appearance_index = plat.findCall(.set_appearance).?;
    try testing.expectEqual(@as(u64, 1), plat.calls[appearance_index].detail);
}

test "platform_init is the first record and window_init follows registration" {
    // Deterministic ordering of the lifecycle records themselves.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    try testing.expectEqual(CallTag.platform_init, plat.calls[0].tag);
    try testing.expectEqual(Lifecycle.running, plat.calls[0].lifecycle);

    const options = makeOptions(16, 16);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    const register_index = plat.findCall(.register_window).?;
    const init_index = plat.findCall(.window_init).?;
    try testing.expect(register_index < init_index);
    try testing.expectEqual(
        @as(u64, win.getWindowId().raw()),
        plat.calls[register_index].detail,
    );
}

test "call log room predicate flips at exactly capacity" {
    // The log panics on exhaustion by design, so the boundary is asserted on
    // the guard predicate rather than by triggering the panic. Method: drive
    // the log to exactly `call_count_max` with an operation that records once
    // and nothing else, then check the predicate.
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);

    try testing.expect(plat.callLogHasRoom());

    while (plat.call_count < call_count_max) {
        const room_before = plat.callLogHasRoom();
        try testing.expect(room_before);
        plat.recordCall(.platform_quit, .invalid, 0);
    }

    try testing.expectEqual(call_count_max, plat.call_count);
    try testing.expect(!plat.callLogHasRoom());

    // `deinit` records, so tearing down a full log would panic. Drop straight
    // to the terminal lifecycle instead; nothing here owns a resource.
    plat.lifecycle = .deinitialized;
}

test "frame log room predicate flips at exactly capacity" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);

    var scene: scene_mod.Scene = undefined;

    try testing.expect(plat.frameLogHasRoom());
    while (plat.frame_count < frame_record_count_max) {
        try testing.expect(plat.frameLogHasRoom());
        plat.recordFrame(WindowId.fromRaw(1), &scene);
    }

    try testing.expectEqual(frame_record_count_max, plat.frame_count);
    try testing.expect(!plat.frameLogHasRoom());

    // Frame records must stay ordered and stamped from the shared counter.
    var previous: u64 = 0;
    for (plat.frames[0..plat.frame_count]) |record| {
        try testing.expect(record.sequence > previous);
        previous = record.sequence;
    }

    plat.lifecycle = .deinitialized;
}

test "setScene records a frame alongside the call" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(16, 16);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    var scene: scene_mod.Scene = undefined;
    win.setScene(&scene);

    try testing.expectEqual(@as(u32, 1), plat.frame_count);
    try testing.expectEqual(win.getWindowId(), plat.frames[0].window_id);
    try testing.expect(plat.frames[0].scene == &scene);
    try testing.expect(plat.findCall(.set_scene) != null);
}

test "atlas setters store the pointer they were handed" {
    var plat: TestPlatform = undefined;
    try initPlatform(&plat);
    defer plat.deinit();

    const options = makeOptions(16, 16);
    const win = try TestWindow.init(testing.allocator, &plat, &options);
    defer win.deinit();

    var text_atlas: text_mod.Atlas = undefined;
    var svg_atlas: text_mod.Atlas = undefined;
    var image_atlas: text_mod.Atlas = undefined;

    win.setTextAtlas(&text_atlas);
    win.setSvgAtlas(&svg_atlas);
    win.setImageAtlas(&image_atlas);

    // The three slots were historically easy to cross-wire, so pin identity.
    try testing.expect(win.text_atlas == &text_atlas);
    try testing.expect(win.svg_atlas == &svg_atlas);
    try testing.expect(win.image_atlas == &image_atlas);
}

test "fixed registry matches the production registry's observable semantics" {
    var registry: FixedWindowRegistry = undefined;
    registry.initInPlace();

    var a: u32 = 1;
    var b: u32 = 2;

    const id_a = try registry.register(&a);
    const id_b = try registry.register(&b);
    try testing.expect(id_a != id_b);
    try testing.expectEqual(@as(u32, 2), registry.count());

    // Registration is a pure map operation: electing an active window is the
    // backend's job, mirroring `interface.WindowRegistry.register`.
    try testing.expect(registry.getActive() == null);
    registry.setActive(id_a);
    try testing.expectEqual(id_a, registry.getActive().?);

    try testing.expect(registry.get(id_a) == @as(*anyopaque, @ptrCast(&a)));
    try testing.expect(registry.get(.invalid) == null);
    try testing.expect(!registry.contains(.invalid));

    try testing.expect(registry.unregister(id_a) != null);
    try testing.expect(registry.unregister(id_a) == null);
    try testing.expectEqual(@as(u32, 1), registry.count());
    try testing.expect(registry.getActive() == null);

    _ = registry.unregister(id_b);
    try testing.expectEqual(@as(u32, 0), registry.count());
}

test "fixed registry fills exactly to capacity and zeroes released slots" {
    var registry: FixedWindowRegistry = undefined;
    registry.initInPlace();

    var owners: [window_count_max]u32 = undefined;
    var ids: [window_count_max]WindowId = undefined;

    for (0..window_count_max) |index| {
        owners[index] = @intCast(index);
        ids[index] = try registry.register(&owners[index]);
    }
    try testing.expectEqual(window_count_max, registry.count());

    var extra: u32 = 0;
    try testing.expectError(error.WindowSlotsExhausted, registry.register(&extra));
    try testing.expectEqual(window_count_max, registry.count());

    // A released slot must not retain the previous id, or a stale lookup could
    // resolve to the next occupant.
    _ = registry.unregister(ids[3]);
    for (&registry.slots) |*slot| {
        if (slot.window != null) continue;
        try testing.expectEqual(WindowId.invalid, slot.id);
    }

    const replacement = try registry.register(&extra);
    try testing.expect(replacement != ids[3]);
    try testing.expectEqual(window_count_max, registry.count());
}

test "capacity constants keep their documented relationships" {
    try testing.expect(event_count_frame_max <= event_count_max);
    try testing.expect(frame_record_count_max <= call_count_max);
    try testing.expect(window_count_max <= interface.WindowRegistry.MAX_WINDOWS);
    try testing.expect(title_bytes_max > 0);
    try testing.expect(framebuffer_dimension_max > 0);
}

test "capabilities advertise only what a headless backend can honour" {
    // A backend that claimed GPU or clipboard support would let capability-
    // gated code paths go unexercised on the one backend that can test them.
    try testing.expect(!TestPlatform.capabilities.gpu_accelerated);
    try testing.expect(!TestPlatform.capabilities.display_link);
    try testing.expect(!TestPlatform.capabilities.clipboard);
    try testing.expect(TestPlatform.capabilities.ime);
    try testing.expectEqualStrings("test-headless", TestPlatform.capabilities.name);
}
