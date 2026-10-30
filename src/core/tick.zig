//! The per-window frame driver (contract §5).
//!
//! drain → build → layout → emit → pack → draw → swap, with every phase
//! transition asserted. Drain routes every queued event against the rendered
//! frame and then opens at most one requested file dialog, on the main
//! thread, outside any handler. Build through draw run only when something
//! requested a render. Milestone 1 packs and draws on the calling thread; the
//! render thread of contract rule 1 arrives with the macOS display link.

const std = @import("std");
const records = @import("records.zig");
const window_mod = @import("window.zig");
const cx_mod = @import("cx.zig");
const emit_mod = @import("emit.zig");
const pack_mod = @import("pack.zig");
const router = @import("router.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;

/// Run one tick of `window` for `app`, whose type declares the root
/// `render` function.
pub fn tick(app: anytype, window: *Window, now_ns: u64) void {
    const App = @TypeOf(app.*);
    assert(now_ns >= window.now_ns);
    window.now_ns = now_ns;
    window.text_scratch_allocator.reset();
    drain(window);
    if (!window.render_requested) return;
    window.render_requested = false;

    window.setPhase(.idle, .build);
    window.frame_number += 1;
    window.built().reset(window.frame_number, .{
        .width = window.width,
        .height = window.height,
        .scale_factor = window.scale_factor,
    });
    cx_mod.beginBuild(window);
    App.render(&window.cx);
    cx_mod.endBuild(window);

    window.setPhase(.build, .layout);
    _ = window.layout.endFrame() catch |err| std.debug.panic("layout failed in frame {d}: {s}", .{
        window.frame_number,
        @errorName(err),
    });

    window.setPhase(.layout, .emit);
    emit_mod.emit(window);
    router.validateFocus(window);
    _ = window.retained.sweep(window.frame_number, &window.keys);
    _ = window.inputs.slab.sweep(
        window.frame_number,
        window.limits.retained.sweep_delay_frames,
        &window.keys,
    );

    window.setPhase(.emit, .pack);
    pack_mod.pack(window.built(), window.scene);

    window.setPhase(.pack, .draw);
    if (window.presenter) |presenter| presenter.draw(presenter.context, window.scene, window);
    window.built_index ^= 1;
    window.setPhase(.draw, .idle);
    // The new frame may have moved what the pointer is over.
    router.updateHover(window);
}

fn drain(window: *Window) void {
    window.setPhase(.idle, .drain);
    window.completions.drainInto(&window.queue);
    const pending = window.queue.pending();
    for (pending) |*event| router.route(window, event);
    window.queue.clear();
    if (window.pending_dialog) |request| {
        window.pending_dialog = null;
        openDialog(window, request);
    }
    window.setPhase(.drain, .idle);
}

/// Open a requested file dialog on the main thread and queue its outcome
/// for the next tick's drain. A platform's modal dialog runs its own event
/// loop here; the core is between handlers, so nothing re-enters it.
fn openDialog(window: *Window, request: @import("handler.zig").FileDialogRequest) void {
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
        request,
    );
    window.queue.push(.{ .completion = .{ .request_id = request_id, .outcome = outcome } });
    window.render_requested = true;
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
