//! The per-window frame driver (contract §5).
//!
//! drain → build → layout → emit → pack → draw → swap, with every phase
//! transition asserted. Drain routes every queued event against the rendered
//! frame and then opens at most one requested file dialog, on the main
//! thread, outside any handler. Build through draw run only when something
//! requested a render.
//!
//! Two sides, one owner each (contract rule 1). `tickMain` runs on the main
//! thread: drain, build, layout, emit, then it publishes the built frame by
//! setting `frame_in_flight`. `presentBuilt` runs on the render side: pack,
//! draw, then it clears the flag. While a frame is in flight the main thread
//! still drains (handlers read only the rendered frame) but neither builds
//! nor flips, so the frame, the atlases, and their upload journal each have
//! one writer at a time. The main thread makes a drawn frame `rendered` at
//! its next tick. TestBackend runs both sides in order on one thread.

const std = @import("std");
const records = @import("records.zig");
const window_mod = @import("window.zig");
const cx_mod = @import("cx.zig");
const emit_mod = @import("emit.zig");
const pack_mod = @import("pack.zig");
const router = @import("router.zig");
const screen_reader = @import("screen_reader.zig");
const debugger = @import("debugger.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;

/// One synchronous tick: both sides on the calling thread (TestBackend).
pub fn tick(app: anytype, window: *Window, now_ns: u64) void {
    if (tickMain(app, window, now_ns)) presentBuilt(window);
    flipPresented(window);
}

/// The main-thread side. Returns true when it published a frame that the
/// render side must present. A render requested while a frame is in flight
/// stays requested for a later tick.
pub fn tickMain(app: anytype, window: *Window, now_ns: u64) bool {
    const App = @TypeOf(app.*);
    assert(now_ns >= window.now_ns);
    window.now_ns = now_ns;
    flipPresented(window);
    const in_flight = window.frame_in_flight.load(.acquire);
    // Shaped runs of the frame in flight may still sit in the scratch.
    if (!in_flight) window.text_scratch_allocator.reset();
    // The tick that ran a dialog builds nothing: the frame would show the
    // state from before the outcome, which only the next drain delivers. On
    // macOS that extra frame, presented as the modal session ends, can make
    // Core Animation discard the next one, leaving the stale frame on screen.
    // The render stays requested and the host ticks again for the queued
    // outcome, so the next build shows it.
    if (drain(window)) {
        assert(window.render_requested);
        return false;
    }
    fireDeadline(window, now_ns);
    // A reload clears the glyph cache and atlas the render side reads while
    // it draws, so it waits for a tick with no frame in flight.
    if (!in_flight) applyFont(window);
    if (!window.render_requested) return false;
    if (in_flight) return false;
    window.render_requested = false;

    buildFrame(App, window);
    // An item skipped because this frame's upload staging was full is staged
    // by the next frame (`AtlasLimits.upload_bytes_frame_max`).
    if (window.resources.atlas_uploads.deferredSince(window.atlas_frame)) {
        window.render_requested = true;
    }
    publish(window);
    return true;
}

/// Build, lay out, and emit one frame into the built slot. Runs only with no
/// frame in flight, so the main thread is the slot's only writer, and leaves
/// the window back in the idle phase.
fn buildFrame(comptime App: type, window: *Window) void {
    assert(!window.frame_in_flight.load(.acquire));
    assert(!window.render_requested);
    window.setPhase(.idle, .build);
    if (window.resources.text_system.scale_factor != window.scale_factor) {
        window.resources.setScaleFactor(window.scale_factor);
    }
    window.frame_number += 1;
    // Open this build's atlas frame: items used from here on stay resident
    // until the renderer uploads them, and items only older frames used may
    // be evicted. Without it every glyph stays protected and the atlas fills.
    window.atlas_frame = window.resources.atlas_uploads.beginFrame(window.atlas_consumer_key);
    window.built().reset(window.frame_number, .{
        .width = window.width,
        .height = window.height,
        .scale_factor = window.scale_factor,
    });
    // No frame is in flight here, so the render side reads neither until
    // this frame is published.
    window.built().announcements = window.announcements;
    window.announcements.clear();
    window.clear_color = window.theme.bg;
    const build_ns = debugger.stamp(window);
    debugger.beginBuild();
    cx_mod.beginBuild(window);
    App.render(&window.cx);
    cx_mod.endBuild(window);

    window.setPhase(.build, .layout);
    const layout_ns = debugger.stamp(window);
    window.layout.endFrame() catch |err| std.debug.panic("layout failed in frame {d}: {s}", .{
        window.frame_number,
        @errorName(err),
    });
    window.noteLayoutArenaUse();

    window.setPhase(.layout, .emit);
    const emit_ns = debugger.stamp(window);
    emit_mod.emit(window);
    router.validateFocus(window);
    _ = window.retained.sweep(window.frame_number, &window.keys);
    _ = window.inputs.slab.sweep(
        window.frame_number,
        window.limits.retained.sweep_delay_frames,
        &window.keys,
    );
    // The debugger's overlay paints last, over every layer.
    debugger.finishBuild(window, .{ .build = build_ns, .layout = layout_ns, .emit = emit_ns });
    window.setPhase(.emit, .idle);
    assert(window.built().frame_number == window.frame_number);
}

/// The render side: pack the published frame, draw it, and hand it back.
/// Reads only the built frame, which the main thread leaves alone while it is
/// in flight, and writes only the packed frame and the presenter's renderer.
pub fn presentBuilt(window: *Window) void {
    assert(window.frame_in_flight.load(.acquire));
    assert(window.render_phase == .idle);
    const frame = &window.frames[window.built_index];
    window.render_phase = .pack;
    const pack_ns = debugger.stamp(window);
    pack_mod.pack(frame, &window.packed_frame);
    window.render_phase = .draw;
    const draw_ns = debugger.stamp(window);
    if (window.presenter) |presenter| {
        presenter.draw(presenter.context, &window.packed_frame, frame, window.clear_color);
    }
    debugger.notePresent(window, pack_ns, draw_ns);
    window.render_phase = .idle;
    window.frame_in_flight.store(false, .release);
}

fn publish(window: *Window) void {
    assert(!window.awaiting_flip);
    assert(!window.frame_in_flight.load(.monotonic));
    window.awaiting_flip = true;
    window.frame_in_flight.store(true, .release);
}

/// Make the last presented frame `rendered`, on the main thread. The new
/// frame may have moved what the pointer is over.
fn flipPresented(window: *Window) void {
    assert(window.phase == .idle);
    if (!window.awaiting_flip) return;
    if (window.frame_in_flight.load(.acquire)) return;
    window.awaiting_flip = false;
    window.built_index ^= 1;
    router.updateHover(window);
    screen_reader.publish(
        window.screen_reader,
        &window.screen_reader_poll,
        window.rendered(),
        window.now_ns,
    );
}

/// Request the render the last build asked for once its deadline passes
/// (`cx.requestRenderAfter`). The deadline is spent here: the build it
/// requests renews it if the view still depends on the clock.
fn fireDeadline(window: *Window, now_ns: u64) void {
    assert(window.phase == .idle);
    const deadline = window.renderDeadlineNs() orelse return;
    if (now_ns < deadline) return;
    window.render_requested = true;
    window.render_deadline_ns = window_mod.deadline_none;
}

/// Reload the app family a handler asked for (`Effects.setFont`), after the
/// drain. A family that fails to load is an operating error: the text system
/// keeps the previous one, and the failure is logged with the name.
fn applyFont(window: *Window) void {
    assert(window.phase == .idle);
    const pending = window.pending_font orelse return;
    window.pending_font = null;
    assert(!window.frame_in_flight.load(.acquire));
    window.resources.text_system.loadFont(pending.name(), pending.size) catch |err| {
        std.log.err("effects.setFont(\"{s}\", {d}) failed: {s}; the previous font stays", .{
            pending.name(),
            pending.size,
            @errorName(err),
        });
    };
    window.render_requested = true;
}

/// Route every queued event. Returns whether a file dialog ran to completion
/// in this drain; one that stays open completes in a later tick.
fn drain(window: *Window) bool {
    window.setPhase(.idle, .drain);
    window.completions.drainInto(&window.queue, &window.images.landed);
    // A landed decode is uploaded and drawn by the next build's emit.
    if (window.images.landed != null) window.render_requested = true;
    const pending = window.queue.pending();
    for (pending) |*event| router.route(window, event);
    window.queue.clear();
    // Copy and cut reach the platform after the drain, outside any handler.
    window.clipboard.flush();
    // Entities removed by this drain's handlers leave before the build.
    window.store.freeRemoved();
    var dialog_ran = false;
    if (window.pending_dialog) |request| {
        window.pending_dialog = null;
        dialog_ran = openDialog(window, request);
        if (dialog_ran) assert(window.queue.count > 0); // Its outcome, for the next drain.
    }
    window.setPhase(.drain, .idle);
    return dialog_ran;
}

/// Open a requested file dialog on the main thread. A platform's modal
/// dialog runs its own event loop here and its outcome is queued for the next
/// tick's drain; the core is between handlers, so nothing re-enters it.
/// Returns false when the dialog stays open: the backend queues the outcome
/// with the request's id once it closes (`FileDialogService`).
fn openDialog(window: *Window, request: @import("handler.zig").FileDialogRequest) bool {
    const service = window.file_dialog orelse std.debug.panic(
        "a file dialog was requested but this backend binds no file dialog service",
        .{},
    );
    const request_id = freeDialogSlot(window);
    window.dialog_handlers[request_id] = request.on_complete;
    window.dialogs_opened += 1;
    const outcome = service.open(
        service.context,
        window.text_scratch_allocator.allocator(),
        request_id,
        request,
    ) orelse {
        assert(window.dialog_handlers[request_id] != null);
        return false;
    };
    switch (outcome) {
        .file_selected => |paths| {
            checkSelection(window, selectsMany(request), paths.count, paths.bytes.len);
        },
        .cancelled, .failed => {},
    }
    window.queue.push(.{ .completion = .{ .request_id = request_id, .outcome = outcome } });
    window.render_requested = true;
    return true;
}

/// Whether `request` may select more than one path.
pub fn selectsMany(request: @import("handler.zig").FileDialogRequest) bool {
    return switch (request.kind) {
        .open => |options| options.multiple,
        .save => false,
    };
}

/// A selection past `ResourceLimits.events` fails fast (decision 11); one
/// the request could not produce is the platform's bug. Public for a backend
/// that completes a dialog later: it checks its selection's totals here
/// before it queues the completion, even when they exceed its buffer.
pub fn checkSelection(window: *const Window, many: bool, count: u32, bytes_len: u64) void {
    assert(count > 0);
    if (!many) assert(count == 1);
    // Every path holds at least one byte, and NUL bytes separate them.
    assert(bytes_len >= @as(u64, count) * 2 - 1);
    const limits = &window.limits.events;
    if (count > limits.dialog_path_count_max) {
        std.debug.panic("file dialog selected {d} paths: capacity {d}. Raise " ++
            "ResourceLimits.events.dialog_path_count_max.", .{
            count,
            limits.dialog_path_count_max,
        });
    }
    if (bytes_len > limits.dialog_path_bytes_max) {
        std.debug.panic("file dialog selected {d} bytes of paths: capacity {d}. Raise " ++
            "ResourceLimits.events.dialog_path_bytes_max.", .{
            bytes_len,
            limits.dialog_path_bytes_max,
        });
    }
}

fn freeDialogSlot(window: *Window) u32 {
    for (window.dialog_handlers, 0..) |slot, index| {
        if (slot == null) return @intCast(index);
    }
    std.debug.panic("file dialog requests exhausted: capacity {d}, {d} in use, 1 requested", .{
        window_mod.dialog_count_max,
        window_mod.dialog_count_max,
    });
}

comptime {
    assert(window_mod.dialog_count_max > 0);
    assert(@sizeOf(records.Record) <= 96);
}
