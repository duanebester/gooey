//! CVDisplayLink wrapper for vsync-synchronized rendering
//!
//! CVDisplayLink provides a high-priority thread that fires callbacks
//! synchronized with the display's refresh rate.
//!
//! Reference: https://developer.apple.com/documentation/corevideo/cvdisplaylink
//!
//! ## Why CVDisplayLink and not CADisplayLink?
//!
//! `CADisplayLink` is the newer Core Animation API (macOS 14+) and is what
//! Apple nudges you toward in current docs. We deliberately stay on
//! `CVDisplayLink` for two reasons:
//!
//! 1. **Dedicated vsync thread, not the run loop.** `CVDisplayLink` fires
//!    on a CoreVideo-managed high-priority thread. `CADisplayLink` on macOS
//!    dispatches via the main run loop, which also services AppKit events,
//!    `NSTimer` callbacks, tracking areas, etc. For an immediate-mode
//!    renderer that wants to sprint on each vsync without run-loop jitter,
//!    the dedicated thread is the better primitive.
//! 2. **Direct ProMotion pinning.** `CVDisplayLinkSetCurrentCGDisplay`
//!    reliably binds the link to a specific display's refresh rate.
//!    `CADisplayLink`'s `preferredFrameRateRange` is a hint that macOS is
//!    free to adaptively ignore.
//!
//! ## Prior art — Zed's GPUI (`crates/gpui_macos/src/display_link.rs`)
//!
//! Zed (a production GPU-accelerated editor) also uses `CVDisplayLink`
//! rather than `CADisplayLink`, explicitly citing older-macOS support as
//! the reason to stay. Two design points worth knowing:
//!
//! - **Main-thread bounce.** Zed's CV callback does not render on the
//!   vsync thread. It posts a GCD `DISPATCH_SOURCE_TYPE_DATA_ADD` source
//!   targeting `DispatchQueue::main()`, and the user's render callback
//!   runs on the main thread. Trades one context switch of frame latency
//!   for zero render-state synchronization and automatic coalescing of
//!   backed-up vsync ticks. Gooey makes the opposite choice: render
//!   directly on the vsync thread and synchronize via `Window.render_mutex`
//!   (see `src/platform/mutex.zig`). Either is defensible; ours is
//!   lower-latency at the cost of the one mutex.
//! - **Release-on-drop crash.** Zed observed sporadic segfaults from
//!   `CVDisplayLinkRelease` racing with the CV timer thread, and their
//!   fix is to `mem::forget` the display link rather than release it.
//!   We call `CVDisplayLinkRelease` in `deinit` today; if we ever see
//!   matching crash reports on window close, leaking the link is the
//!   known-good workaround (per-window lifetime, bounded cost).

const std = @import("std");
const objc = @import("objc");

// ============================================================================
// CoreVideo Types
// ============================================================================

/// Opaque reference to a CVDisplayLink
pub const CVDisplayLinkRef = *opaque {};

/// CVReturn error codes
pub const CVReturn = enum(i32) {
    success = 0,
    first = -6660,
    invalid_argument = -6661,
    allocation_failed = -6662,
    unsupported = -6663,
    // Display link specific
    invalid_display = -6670,
    display_link_already_running = -6671,
    display_link_not_running = -6672,
    display_link_callbacks_not_set = -6673,
    _,

    pub fn isSuccess(self: CVReturn) bool {
        return self == .success;
    }
};

/// CVTimeStamp - timing information passed to display link callback
pub const CVTimeStamp = extern struct {
    version: u32,
    video_time_scale: i32,
    video_time: i64,
    host_time: u64,
    rate_scalar: f64,
    video_refresh_period: i64,
    smpte_time: SMPTETime,
    flags: u64,
    reserved: u64,
};

/// SMPTE timecode format
pub const SMPTETime = extern struct {
    subframes: i16,
    subframe_divisor: i16,
    counter: u32,
    type: u32,
    flags: u32,
    hours: i16,
    minutes: i16,
    seconds: i16,
    frames: i16,
};

/// CVDisplayLink output callback signature
pub const CVDisplayLinkOutputCallback = *const fn (
    display_link: CVDisplayLinkRef,
    in_now: *const CVTimeStamp,
    in_output_time: *const CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    user_info: ?*anyopaque,
) callconv(.c) CVReturn;

// ============================================================================
// CoreVideo External Functions
// ============================================================================

/// Create a display link for the active displays
pub extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(
    display_link_out: *?CVDisplayLinkRef,
) CVReturn;

/// Set the output callback for the display link
pub extern "c" fn CVDisplayLinkSetOutputCallback(
    display_link: CVDisplayLinkRef,
    callback: CVDisplayLinkOutputCallback,
    user_info: ?*anyopaque,
) CVReturn;

/// Start the display link
pub extern "c" fn CVDisplayLinkStart(display_link: CVDisplayLinkRef) CVReturn;

/// Stop the display link
pub extern "c" fn CVDisplayLinkStop(display_link: CVDisplayLinkRef) CVReturn;

/// Check if display link is running
pub extern "c" fn CVDisplayLinkIsRunning(display_link: CVDisplayLinkRef) bool;

/// Release the display link
pub extern "c" fn CVDisplayLinkRelease(display_link: CVDisplayLinkRef) void;

/// Get the nominal refresh rate
pub extern "c" fn CVDisplayLinkGetNominalOutputVideoRefreshPeriod(
    display_link: CVDisplayLinkRef,
) CVTime;

/// CVTime for refresh period
pub const CVTime = extern struct {
    time_value: i64,
    time_scale: i32,
    flags: i32,
};

/// Set the current display for the display link.
/// This ensures consistent frame rate on ProMotion displays by binding
/// the display link to a specific display rather than letting macOS
/// adaptively change the refresh rate based on content.
pub extern "c" fn CVDisplayLinkSetCurrentCGDisplay(
    display_link: CVDisplayLinkRef,
    display_id: u32,
) CVReturn;

/// Get the main display ID (from CoreGraphics)
pub extern "c" fn CGMainDisplayID() u32;

// ============================================================================
// DisplayLink Wrapper
// ============================================================================

/// Render callback type - called on vsync
pub const RenderCallback = *const fn (user_data: ?*anyopaque) void;

/// High-level wrapper around CVDisplayLink
pub const DisplayLink = struct {
    link: CVDisplayLinkRef,
    running: std.atomic.Value(bool),

    const Self = @This();

    /// Create a new display link (callback must be set before starting)
    pub fn init() !Self {
        var link: ?CVDisplayLinkRef = null;

        // Create display link for active displays
        const create_result = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        if (!create_result.isSuccess() or link == null) {
            return error.DisplayLinkCreationFailed;
        }

        // Bind to main display for consistent frame rate on ProMotion displays.
        // Without this, macOS may adaptively lower the refresh rate (e.g., 120Hz -> 60Hz)
        // after user interaction when it thinks the app doesn't need high frame rate.
        const main_display = CGMainDisplayID();
        _ = CVDisplayLinkSetCurrentCGDisplay(link.?, main_display);

        return Self{
            .link = link.?,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// Set the render callback and user data
    /// IMPORTANT: user_data must point to memory that outlives the DisplayLink!
    pub fn setCallback(self: *Self, callback: CVDisplayLinkOutputCallback, user_data: ?*anyopaque) !void {
        const result = CVDisplayLinkSetOutputCallback(self.link, callback, user_data);
        if (!result.isSuccess()) {
            return error.DisplayLinkCallbackFailed;
        }
    }

    /// Start the display link (begins vsync callbacks)
    pub fn start(self: *Self) !void {
        const result = CVDisplayLinkStart(self.link);
        if (!result.isSuccess()) {
            return error.DisplayLinkStartFailed;
        }
        self.running.store(true, .release);
    }

    /// Stop the display link
    pub fn stop(self: *Self) void {
        if (self.running.load(.acquire)) {
            _ = CVDisplayLinkStop(self.link);
            self.running.store(false, .release);
        }
    }

    /// Check if running
    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }

    /// Clean up resources.
    ///
    /// Zed's GPUI (`crates/gpui_macos/src/display_link.rs`) deliberately
    /// leaks the `CVDisplayLink` here via `mem::forget` to avoid sporadic
    /// segfaults from `CVDisplayLinkRelease` racing with the CV timer
    /// thread. We release it cleanly — `stop()` synchronously returns
    /// before `CVDisplayLinkRelease` runs, so the race window should be
    /// closed. If we ever see matching crashes on window close, skipping
    /// the release call is the known-good workaround.
    pub fn deinit(self: *Self) void {
        self.stop();
        CVDisplayLinkRelease(self.link);
    }

    /// Get refresh rate in Hz
    pub fn getRefreshRate(self: *const Self) f64 {
        const period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(self.link);
        if (period.time_scale > 0 and period.time_value > 0) {
            return @as(f64, @floatFromInt(period.time_scale)) /
                @as(f64, @floatFromInt(period.time_value));
        }
        return 60.0; // Default fallback
    }
};

/// Helper to create a simple callback that just calls a Zig function
pub fn makeDisplayLinkCallback(
    display_link: CVDisplayLinkRef,
    in_now: *const CVTimeStamp,
    in_output_time: *const CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    user_info: ?*anyopaque,
) callconv(.c) CVReturn {
    _ = display_link;
    _ = in_now;
    _ = in_output_time;
    _ = flags_in;
    _ = flags_out;
    _ = user_info;
    return .success;
}
