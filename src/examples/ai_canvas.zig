//! AI Canvas — Example App + Stdin Transport (Phase 5)
//!
//! Integration example that wires Phases 1–4 into a running Gooey application.
//! An LLM (or any external process) sends JSON-lines on stdin; this app parses
//! them into DrawCommands and renders them on a canvas in real time.
//!
//! **Native:** A background thread reads stdin line-by-line. Three `AiCanvas`
//! buffers are rotated via atomic index swaps — no mutexes, no data races.
//! The render thread always displays the most recently committed batch.
//!
//! **WASM:** Single-threaded, single buffer. Commands are pushed from JS via
//! an exported function (future — stdin is not available on WASM).
//!
//! Usage (pipe JSON commands from any language):
//!
//!   echo '{"tool":"set_background","color":"87CEEB"}
//!   {"tool":"fill_rect","x":200,"y":250,"w":200,"h":150,"color":"8B4513"}
//!   {"tool":"fill_triangle","x1":180,"y1":250,"x2":300,"y2":120,"x3":420,"y3":250,"color":"CC3333"}
//!   {"tool":"draw_text","text":"Home","x":260,"y":410,"color":"FFFFFF","font_size":20}
//!   ' | zig-out/bin/ai-canvas
//!
//! An empty line between groups commits the current batch and starts a new one.
//! If no empty line is sent, commands accumulate until stdin closes (EOF),
//! at which point the final batch is committed automatically.

const std = @import("std");

const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const ai = gooey.ai;
const AiCanvas = ai.AiCanvas;
const Theme = ui.Theme;

/// WASM-compatible logging — redirect std.log to console.log via JS imports.
pub const std_options = gooey.std_options;

// =============================================================================
// Constants (CLAUDE.md #4: put a limit on everything)
// =============================================================================

const WINDOW_WIDTH: f32 = 840;
const WINDOW_HEIGHT: f32 = 640;
const CANVAS_WIDTH: f32 = 800;
const CANVAS_HEIGHT: f32 = 600;

/// Reader buffer for stdin. Must be >= MAX_LINE_SIZE so `takeDelimiter` can
/// find a newline within one buffer fill. 2x gives headroom for the reader's
/// internal bookkeeping and reduces syscall frequency.
const READER_BUF_SIZE: usize = ai.MAX_JSON_LINE_SIZE * 2;

/// Fixed scratch buffer for JSON parsing in the reader thread.
/// Avoids heap allocation during steady-state operation (CLAUDE.md #2).
const JSON_PARSE_BUF_SIZE: usize = 64 * 1024;

/// Maximum bytes per stdin line (matches json_parser constant).
const MAX_LINE_SIZE: usize = ai.MAX_JSON_LINE_SIZE;

/// Sentinel: reader thread has not been spawned yet.
const READER_NOT_STARTED: u8 = 0;
/// Sentinel: reader thread is running and reading stdin.
const READER_RUNNING: u8 = 1;
/// Sentinel: reader thread finished (EOF or error).
const READER_DONE: u8 = 2;

const is_native = !platform.is_wasm;

// =============================================================================
// Triple-Buffer State (Native) / Single Buffer (WASM)
//
// On native, three AiCanvas instances live in global memory (~840KB total).
// Each buffer is owned by exactly one role at any time:
//   - Writer  (background thread): pushes parsed commands
//   - Display (render thread):     replays commands via DrawContext
//   - Ready   (mailbox):           last committed batch, swapped atomically
//
// On WASM, a single buffer suffices — no threads, no contention.
// =============================================================================

// --- Native triple-buffer globals ---
var buffers: if (is_native) [3]AiCanvas else [0]AiCanvas =
    if (is_native) .{ .{}, .{}, .{} } else .{};
var write_idx: u8 = 0;
var ready_idx: u8 = 1;
var display_idx: u8 = 2;

/// Atomic flag: writer sets true on commit, renderer clears on acquire.
/// Guards against triple-buffer oscillation — without this, the renderer
/// unconditionally swaps display_idx↔ready_idx every frame, ping-ponging
/// between the committed batch and an empty buffer when the writer is idle.
var batch_available: bool = false;

/// Tracks reader thread lifecycle so the render function can show status.
var reader_status: u8 = READER_NOT_STARTED;

/// Count of total commands received (monotonically increasing, for UI display).
var total_commands_received: u32 = 0;

/// Count of total batches committed.
var total_batches_committed: u32 = 0;

// --- WASM single-buffer global ---
var wasm_canvas: AiCanvas = .{};

/// Active theme for AI canvas replay. Theme tokens in draw commands resolve
/// against this at paint time. Defaults to dark (matches the app background).
/// Set by the render function so the paint callback can access it without
/// changing the `fn (*DrawContext) void` paint signature.
var active_theme: *const Theme = &Theme.dark;

// =============================================================================
// Application State (minimal — most state is in the global buffers)
// =============================================================================

const AppState = struct {
    /// Placeholder — the real state lives in the global triple-buffer.
    /// AppState exists because gooey.App requires a state type.
    _pad: u8 = 0,
};

var state = AppState{};

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "AI Canvas",
    .width = WINDOW_WIDTH,
    .height = WINDOW_HEIGHT,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    spawnReaderThread();
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    // Acquire the latest committed batch from the mailbox.
    if (is_native) {
        acquireDisplayBatch();
    }

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 20 },
        .gap = 8,
        .direction = .column,
        .background = ui.Color.hex(0x111122),
    }, .{
        // Status bar (component reads global atomics)
        StatusBar{},
        // Canvas — the paint callback reads from the display buffer
        ui.canvas(CANVAS_WIDTH, CANVAS_HEIGHT, paintAiCanvas),
    }));
}

// =============================================================================
// Status Bar Component
// =============================================================================

const StatusBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const status_u8 = @atomicLoad(u8, &reader_status, .acquire);

        const status_text: []const u8 = switch (status_u8) {
            READER_NOT_STARTED => "Waiting for stdin...",
            READER_RUNNING => "Reading stdin...",
            READER_DONE => "Stdin closed (EOF)",
            else => "Unknown",
        };

        const status_color = switch (status_u8) {
            READER_RUNNING => ui.Color.hex(0x00ff88),
            READER_DONE => ui.Color.hex(0xffaa00),
            else => ui.Color.hex(0x888888),
        };

        const cmd_count = if (is_native)
            buffers[display_idx].commandCount()
        else
            wasm_canvas.commandCount();

        cx.render(ui.hstack(.{ .gap = 20, .alignment = .center }, .{
            ui.text("AI Canvas", .{
                .size = 18,
                .color = ui.Color.hex(0xe0e0ff),
            }),
            ui.text(status_text, .{
                .size = 13,
                .color = status_color,
            }),
            ui.textFmt("cmds: {} | batches: {} | total: {}", .{
                cmd_count,
                @atomicLoad(u32, &total_batches_committed, .acquire),
                @atomicLoad(u32, &total_commands_received, .acquire),
            }, .{
                .size = 13,
                .color = ui.Color.hex(0x8888cc),
            }),
        }));
    }
};

// =============================================================================
// Paint Callback — The comptime/runtime bridge
//
// Called by the rendering pipeline. Reads from the display buffer (which the
// render thread owns exclusively) and replays all commands into DrawContext.
// =============================================================================

fn paintAiCanvas(ctx: *ui.DrawContext) void {
    if (is_native) {
        // CLAUDE.md #3: assert display_idx is in range.
        std.debug.assert(display_idx < 3);
        buffers[display_idx].replay(ctx, active_theme);
    } else {
        wasm_canvas.replay(ctx, active_theme);
    }
}

// =============================================================================
// Triple-Buffer Acquire (Render Thread)
//
// Only swap display_idx with ready_idx when the writer has committed a new
// batch (batch_available flag). Without this gate the renderer would swap
// every frame, oscillating between the committed buffer and an empty one
// whenever the writer is idle — causing visible flicker.
// =============================================================================

fn acquireDisplayBatch() void {
    if (!is_native) return;

    // Only swap when the writer has committed something new.
    if (!@atomicLoad(bool, &batch_available, .acquire)) return;

    // CLAUDE.md #3: assert indices are in valid range.
    std.debug.assert(display_idx < 3);

    const old_ready = @atomicRmw(u8, &ready_idx, .Xchg, display_idx, .acq_rel);

    // CLAUDE.md #3 + #11: the value we got back must be a valid buffer index.
    std.debug.assert(old_ready < 3);

    display_idx = old_ready;

    // Clear flag after acquiring. If the writer commits again between our
    // load and this store, worst case we do one extra no-op acquire next
    // frame — no data loss, no oscillation.
    @atomicStore(bool, &batch_available, false, .release);
}

// =============================================================================
// Triple-Buffer Commit (Writer Thread)
//
// Swap write_idx with ready_idx atomically. The old ready buffer becomes our
// new write buffer (we clear it and reuse). The batch we just built is now
// visible to the render thread on its next acquire.
// =============================================================================

fn commitBatch() void {
    if (!is_native) return;

    // CLAUDE.md #3: assert indices are in valid range.
    std.debug.assert(write_idx < 3);

    const old_ready = @atomicRmw(u8, &ready_idx, .Xchg, write_idx, .acq_rel);

    // CLAUDE.md #3 + #11: the value we got back must be a valid buffer index.
    std.debug.assert(old_ready < 3);

    write_idx = old_ready;
    buffers[write_idx].clearAll();

    _ = @atomicRmw(u32, &total_batches_committed, .Add, 1, .monotonic);

    // Signal the renderer that a new batch is available for acquire.
    @atomicStore(bool, &batch_available, true, .release);
}

// =============================================================================
// Stdin Reader Thread (Native Only)
//
// Reads stdin line-by-line. Each non-empty line is parsed as a JSON command
// and pushed into the write buffer. An empty line commits the current batch.
// On EOF, the final batch is committed automatically.
// =============================================================================

fn spawnReaderThread() void {
    if (!is_native) return;

    const thread = std.Thread.spawn(.{}, stdinReaderLoop, .{}) catch {
        // If thread spawn fails, mark as done so the UI shows an error state.
        @atomicStore(u8, &reader_status, READER_DONE, .release);
        return;
    };
    thread.detach();
}

fn stdinReaderLoop() void {
    @atomicStore(u8, &reader_status, READER_RUNNING, .release);
    defer @atomicStore(u8, &reader_status, READER_DONE, .release);

    stdinReaderLoopInner();
}

/// Inner loop — separated so `defer` in `stdinReaderLoop` always fires.
fn stdinReaderLoopInner() void {
    const stdin = std.fs.File.stdin();
    var read_buf: [READER_BUF_SIZE]u8 = undefined;
    var file_reader = stdin.readerStreaming(&read_buf);

    // Fixed scratch buffer for JSON parsing — no heap growth (CLAUDE.md #2).
    var parse_buf: [JSON_PARSE_BUF_SIZE]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);

    var has_commands = false;

    while (true) {
        fba.reset();

        const line_or_null = file_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Line exceeds buffer — drain until next newline and skip.
                drainToNewline(&file_reader.interface);
                continue;
            },
            error.ReadFailed => break,
        };

        if (line_or_null) |line| {
            const trimmed = trimCr(line);
            processLine(trimmed, fba.allocator(), &has_commands);
        } else {
            // EOF — commit any pending batch.
            if (has_commands) commitBatch();
            return;
        }
    }

    // ReadFailed — commit any pending batch before exiting.
    if (has_commands) commitBatch();
}

// =============================================================================
// Line Processing (split out for 70-line limit — CLAUDE.md #5)
// =============================================================================

fn processLine(
    trimmed: []const u8,
    allocator: std.mem.Allocator,
    has_commands: *bool,
) void {
    // CLAUDE.md #3: assert we're in a valid state.
    std.debug.assert(write_idx < 3);

    // Empty line = batch delimiter.
    if (trimmed.len == 0) {
        if (has_commands.*) {
            commitBatch();
            has_commands.* = false;
        }
        return;
    }

    // Non-empty line — parse and push.
    const cmd = ai.parseCommand(
        allocator,
        trimmed,
        &buffers[write_idx].texts,
    ) orelse return; // Malformed/unknown — silently skip (fail-fast, no crash).

    const pushed = buffers[write_idx].pushCommand(cmd);
    if (pushed) {
        has_commands.* = true;
        _ = @atomicRmw(u32, &total_commands_received, .Add, 1, .monotonic);
    }
}

// =============================================================================
// Stdin Helpers
// =============================================================================

/// After `StreamTooLong`, the reader buffer is full with no delimiter found.
/// Drain buffered data and keep reading until we find the newline (or EOF/error).
/// This discards the entire oversized line so the next read starts fresh.
fn drainToNewline(reader: anytype) void {
    // CLAUDE.md #3: assert we have a reader with the expected methods.
    std.debug.assert(@hasDecl(@TypeOf(reader.*), "tossBuffered"));

    reader.tossBuffered();
    while (true) {
        _ = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                reader.tossBuffered();
                continue;
            },
            error.ReadFailed => return,
        };
        return; // Found delimiter (or EOF) — done draining.
    }
}

/// Trim a trailing '\r' if present (handles \r\n line endings).
fn trimCr(line: []const u8) []const u8 {
    // CLAUDE.md #3: input is bounded by reader buffer size.
    std.debug.assert(line.len <= READER_BUF_SIZE);

    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

// =============================================================================
// Compile-time Assertions (CLAUDE.md rules #3, #4)
// =============================================================================

comptime {
    // Triple-buffer indices must fit in u8.
    std.debug.assert(@sizeOf(u8) == 1);

    // AiCanvas must be under 300KB (matches ai_canvas.zig assertion).
    std.debug.assert(@sizeOf(AiCanvas) < 300 * 1024);

    // JSON parse buffer must accommodate std.json overhead (~4x input).
    std.debug.assert(JSON_PARSE_BUF_SIZE >= MAX_LINE_SIZE * 4);

    // Reader buffer must hold at least one full line for takeDelimiter.
    std.debug.assert(READER_BUF_SIZE >= MAX_LINE_SIZE);

    // Line buffer matches the json_parser's documented maximum.
    std.debug.assert(MAX_LINE_SIZE == 4096);
}

// =============================================================================
// Tests
// =============================================================================

test "trimCr removes trailing carriage return" {
    const with_cr = "hello\r";
    const without_cr = "hello";
    const empty = "";

    try std.testing.expectEqualStrings("hello", trimCr(with_cr));
    try std.testing.expectEqualStrings("hello", trimCr(without_cr));
    try std.testing.expectEqualStrings("", trimCr(empty));
}

test "trimCr preserves interior carriage returns" {
    const interior = "hel\rlo";
    try std.testing.expectEqualStrings("hel\rlo", trimCr(interior));
}

test "comptime assertions hold at runtime" {
    // Mirror the comptime block — these run as runtime tests too.
    try std.testing.expect(@sizeOf(AiCanvas) < 300 * 1024);
    try std.testing.expect(JSON_PARSE_BUF_SIZE >= MAX_LINE_SIZE * 4);
    try std.testing.expect(READER_BUF_SIZE >= MAX_LINE_SIZE);
}

test "triple-buffer indices start valid" {
    // Default values from global state.
    try std.testing.expect(write_idx < 3);
    try std.testing.expect(ready_idx < 3);
    try std.testing.expect(display_idx < 3);

    // All three indices must be distinct.
    try std.testing.expect(write_idx != ready_idx);
    try std.testing.expect(write_idx != display_idx);
    try std.testing.expect(ready_idx != display_idx);

    // No batch available before any commit.
    try std.testing.expect(!@atomicLoad(bool, &batch_available, .acquire));
}
