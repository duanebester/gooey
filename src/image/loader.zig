//! Image Loader - Platform dispatcher
//!
//! Routes to platform-specific image loading backends:
//! - CoreGraphics (macOS) - ImageIO/CoreGraphics
//! - libpng (Linux) - PNG decoding via libpng
//! - null (other platforms) - Returns UnsupportedSource
//!
//! Note: WASM image loading is async and handled separately in
//! `platform/web/image_loader.zig`. The sync API here returns
//! UnsupportedSource on WASM.

const std = @import("std");
const builtin = @import("builtin");
const atlas = @import("atlas.zig");
const ImageData = atlas.ImageData;
const ImageKey = atlas.ImageKey;
const ImageSource = atlas.ImageSource;
const interface_verify = @import("../core/interface_verify.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const backend = if (is_wasm)
    @import("backends/null.zig")
else switch (builtin.os.tag) {
    .macos => @import("backends/coregraphics.zig"),
    .linux => @import("backends/libpng.zig"),
    else => @import("backends/null.zig"),
};

// Compile-time interface verification
comptime {
    interface_verify.verifyImageLoaderModule(@This());
}

// =============================================================================
// Re-export types from backend
// =============================================================================

pub const DecodedImage = backend.DecodedImage;
pub const LoadError = backend.LoadError;

// =============================================================================
// Async Image Loading Types (Phase 4)
// =============================================================================

/// Maximum response body size for URL image fetches (256 MiB).
const MAX_URL_RESPONSE_BYTES: usize = 256 * 1024 * 1024;

/// Maximum URL length for image fetches.
pub const MAX_URL_LENGTH: u32 = 8192;

// =============================================================================
// Retry/Backoff Policy (Task 4.5b)
// =============================================================================
//
// Retry lives in the background fetch task — never in the render path, which
// runs at display refresh rate and must never initiate retries. Transient
// failures (DNS, connect, TLS handshake, HTTP 5xx, I/O) retry with bounded
// exponential backoff + jitter. Permanent failures (HTTP 4xx, bad URL,
// decode error) fail fast — retrying wastes bandwidth on deterministic errors.
//
// Worst-case wall-clock to `.failed`: 500ms + 1s + 2s ≈ 3.5s. The `Image`
// on screen shows a loading placeholder throughout — identical to a slow
// first attempt from the render path's perspective.

/// Maximum fetch attempts for a single URL before surfacing `.failed`.
/// Hardcoded intentionally: tunable policy belongs in a user component that
/// owns its own Io.Group + Queue, not in the stateless render path.
const MAX_FETCH_ATTEMPTS: u32 = 3;

/// Base backoff before the second attempt. Doubled on each subsequent attempt.
/// `u64` matches the shift operand type after the widening below.
const BASE_BACKOFF_MS: u64 = 500;

/// ±JITTER_PERCENT of `base_backoff_ms` is added on each retry. Prevents
/// thundering-herd retry storms when many URLs fail simultaneously (server
/// recovering, transient network partition healing).
const JITTER_PERCENT: u64 = 25;

/// Classification of fetch failure — drives retry decisions in `loadFromUrl`.
/// Split from the underlying Zig error sets so the retry loop has a single,
/// tiny enum to switch on rather than re-classifying dozens of HTTP errors.
const FetchError = error{
    /// Transient: safe to retry. DNS, TCP connect, TLS handshake, HTTP 5xx,
    /// read/write I/O errors, unexpected EOF during body read.
    Transient,
    /// Permanent: retrying cannot help. HTTP 4xx, malformed URL, unsupported
    /// scheme, OOM, response-too-large. Fail fast to free the retry slot.
    Permanent,
};

/// Result of an async image load, delivered through Io.Queue.
/// Produced by background fetch tasks; consumed by the frame loop to cache
/// decoded images in the atlas.
pub const ImageLoadResult = union(enum) {
    /// Image fetched and decoded successfully.
    loaded: struct {
        key: ImageKey,
        width: u32,
        height: u32,
        /// RGBA pixel data — consumer must free with `allocator`.
        pixels: []u8,
        allocator: std.mem.Allocator,
    },
    /// Image fetch or decode failed.
    failed: struct {
        key: ImageKey,
    },

    /// Free pixel data if this is a loaded result. Idempotent.
    pub fn deinit(self: *ImageLoadResult) void {
        switch (self.*) {
            .loaded => |*loaded| {
                if (loaded.pixels.len > 0) {
                    loaded.allocator.free(loaded.pixels);
                    loaded.pixels = &.{};
                }
            },
            .failed => {},
        }
    }
};

// =============================================================================
// ImageLoader — async URL fetch + decode + atlas-cache subsystem
// =============================================================================
//
// Rationale: a single struct that owns the fixed-capacity result queue, the
// in-flight `Io.Group`, and the de-dup / failure sets for URL image loads.
// Encapsulates the prototype pattern used by every later subsystem extraction
// (PR 1 — `image/`; PR 2 — `svg/`; PR 3 — `a11y/`; ...): a single struct, a
// single fixed-capacity queue, a single `Io.Group`, no back-pointer to the
// parent context. See `docs/cleanup-implementation-plan.md` PR 1.
//
// Lifetime: created once per `Gooey` (or `Window` after PR 7), `initInPlace`
// at the parent's final heap address so the embedded `Io.Queue`'s pointer
// to `result_buffer` is stable. `deinit` cancels in-flight fetches and
// closes the queue — blocking is acceptable on the teardown path.

/// Maximum image load results buffered per frame drain.
///
/// Hard cap chosen so the per-frame drain has predictable cost: at 60Hz this
/// is up to 1920 image-completion events/sec, far above realistic URL fetch
/// completion rates. If we ever exceed it, the overflow simply waits for the
/// next frame — the queue is unbounded on the producer side.
pub const MAX_IMAGE_LOAD_RESULTS: u32 = 32;

/// Maximum concurrent pending image URL fetches.
///
/// Caps in-flight `Io.Group.async` tasks. A 64-deep pending set is enough for
/// a dense image grid (8 columns × 8 rows visible). Beyond this, callers
/// receive a silent drop from `enqueueIfRoom` rather than blocking.
pub const MAX_PENDING_IMAGE_LOADS: u32 = 64;

/// Maximum distinct failed image URL hashes remembered per session.
///
/// A URL that fails to fetch (404, DNS failure, TLS error, timeout, ...) is
/// recorded here so subsequent frames short-circuit without re-launching the
/// fetch. Without this, a single 404 would kick off a new fetch every frame
/// (60 req/s) — a quick way to get the user's IP rate-limited.
///
/// Hard cap; if exceeded we fail fast rather than evicting. Retry/backoff
/// policy and LRU eviction are deferred (Task 4.5b).
pub const MAX_FAILED_IMAGE_LOADS: u32 = 128;

/// Async image loader — fetches URL images in the background, drains
/// completed loads each frame, and caches decoded pixels into the atlas.
///
/// The struct is small enough (~5KB) to live by-value inside `Gooey`, but
/// must be initialized in place (`initInPlace`) because `result_queue`
/// holds a pointer into `result_buffer`. Copying the struct after init
/// would dangle that pointer.
pub const ImageLoader = struct {
    /// Backing storage for the bounded `result_queue`.
    /// Sized once at init; never reallocates.
    result_buffer: [MAX_IMAGE_LOAD_RESULTS]ImageLoadResult,

    /// Producer-consumer queue: background fetch tasks push results here,
    /// frame loop drains via `drain` once per frame.
    result_queue: std.Io.Queue(ImageLoadResult),

    /// Lifetime envelope for in-flight fetch tasks. Cancelled on `deinit`
    /// so background fetches unwind cleanly when the window closes.
    fetch_group: std.Io.Group,

    /// In-flight URL fetches, keyed by `ImageKey.source_hash`.
    /// `pending_count` tracks length; the array is treated as a fixed slot map.
    pending_hashes: [MAX_PENDING_IMAGE_LOADS]u64,
    pending_count: u32,

    /// URLs that have failed to fetch this session — short-circuit further
    /// attempts. See `MAX_FAILED_IMAGE_LOADS` for rationale.
    failed_hashes: [MAX_FAILED_IMAGE_LOADS]u64,
    failed_count: u32,

    /// Atlas that decoded pixels are written into on `drain`.
    /// Borrowed reference; `Gooey` (or `App` after PR 7) owns the atlas.
    image_atlas: *atlas.ImageAtlas,

    /// `Io` interface for queue/group ops + background task dispatch.
    /// Captured at init; never replaced.
    io: std.Io,

    /// General-purpose allocator for URL-string ownership transfer to
    /// background tasks. The atlas owns its own allocator separately.
    gpa: std.mem.Allocator,

    const Self = @This();

    /// Initialize in place at the struct's final heap address.
    ///
    /// Marked `noinline` to keep the WASM caller's stack frame bounded
    /// (`CLAUDE.md` §14): inlining lets the compiler combine the result
    /// buffer of every ImageLoader into one giant frame.
    ///
    /// Safe to call only once per instance, before any background tasks
    /// have been spawned. Asserts the queue is wired to its own backing
    /// buffer — a sanity check that catches accidental struct copies.
    pub noinline fn initInPlace(
        self: *Self,
        io: std.Io,
        gpa: std.mem.Allocator,
        image_atlas: *atlas.ImageAtlas,
    ) void {
        std.debug.assert(@intFromPtr(image_atlas) != 0);

        // Field-by-field init avoids a stack temp from a struct literal —
        // the result_buffer alone is ~2.5KB and we do not want to copy
        // that through registers on every init call.
        self.result_buffer = undefined;
        self.fetch_group = .init;
        self.pending_hashes = [_]u64{0} ** MAX_PENDING_IMAGE_LOADS;
        self.pending_count = 0;
        self.failed_hashes = [_]u64{0} ** MAX_FAILED_IMAGE_LOADS;
        self.failed_count = 0;
        self.image_atlas = image_atlas;
        self.io = io;
        self.gpa = gpa;

        // Wire the queue last — it captures `&self.result_buffer`, so
        // every other field must already be at its final address.
        self.result_queue = .init(&self.result_buffer);

        // Pair-assertion: queue must point into our own backing buffer.
        std.debug.assert(@intFromPtr(&self.result_buffer) != 0);
    }

    /// Re-bind the queue's pointer to `&self.result_buffer`.
    ///
    /// By-value init paths in `Gooey` build the surrounding struct on the
    /// stack and copy to heap; the queue's internal pointer dangles after
    /// the copy. This method fixes that. `Ptr`-style init paths do not
    /// need it because they write directly to the final address.
    ///
    /// Asserts no async work has launched yet — a fixup after the first
    /// `enqueue` would corrupt in-flight state.
    pub fn fixupQueue(self: *Self) void {
        std.debug.assert(self.pending_count == 0);
        std.debug.assert(self.fetch_group.token.raw == null);
        self.result_queue = .init(&self.result_buffer);
    }

    /// Cancel in-flight fetches and close the result queue.
    /// Blocking is acceptable here — we are tearing down.
    pub fn deinit(self: *Self) void {
        // Close the queue first so background tasks see closure on their
        // next put attempt and unwind without further allocation.
        self.result_queue.close(self.io);

        // Cancel the group — blocks until every async task completes its
        // current cancel point. Required before `Gooey` can free shared
        // resources (the atlas, the gpa).
        self.fetch_group.cancel(self.io);
    }

    // -------------------------------------------------------------------------
    // Pending / failed bookkeeping
    // -------------------------------------------------------------------------

    /// Check whether a URL fetch is already in flight.
    pub fn isPending(self: *const Self, url_hash: u64) bool {
        for (self.pending_hashes[0..self.pending_count]) |hash| {
            if (hash == url_hash) return true;
        }
        return false;
    }

    /// Check whether a URL has previously failed to fetch.
    ///
    /// Callers should consult this before launching a fetch — a failed URL
    /// stays failed for the session (retry/backoff is Task 4.5b). This
    /// prevents 60 req/s retry storms for broken URLs at frame rate.
    pub fn isFailed(self: *const Self, url_hash: u64) bool {
        for (self.failed_hashes[0..self.failed_count]) |hash| {
            if (hash == url_hash) return true;
        }
        return false;
    }

    /// `true` iff a new fetch can be enqueued without exceeding the cap.
    pub fn hasRoom(self: *const Self) bool {
        return self.pending_count < MAX_PENDING_IMAGE_LOADS;
    }

    fn addPending(self: *Self, url_hash: u64) void {
        std.debug.assert(self.pending_count < MAX_PENDING_IMAGE_LOADS);
        std.debug.assert(!self.isPending(url_hash));
        self.pending_hashes[self.pending_count] = url_hash;
        self.pending_count += 1;
    }

    /// Swap-remove a pending entry. `unreachable` if the hash is not
    /// pending — every drained result must have a matching pending entry.
    fn removePending(self: *Self, url_hash: u64) void {
        for (self.pending_hashes[0..self.pending_count], 0..) |hash, i| {
            if (hash == url_hash) {
                self.pending_count -= 1;
                if (i < self.pending_count) {
                    self.pending_hashes[i] = self.pending_hashes[self.pending_count];
                }
                return;
            }
        }
        unreachable;
    }

    /// Record that a URL fetch has failed permanently for this session.
    ///
    /// All failure modes (404, DNS, TLS, timeout, decode error) collapse to
    /// the same set in 4.5a — nuance belongs in 4.5b. At capacity, fail
    /// fast rather than silently evicting: 128 distinct failed URLs in one
    /// session is a bug to surface, not paper over.
    fn addFailed(self: *Self, url_hash: u64) void {
        // Idempotent: drop duplicates silently. A result can only be
        // reported once, but defensive against future code paths.
        if (self.isFailed(url_hash)) return;
        std.debug.assert(self.failed_count < MAX_FAILED_IMAGE_LOADS);
        // Failed and pending are disjoint: the caller of this method has
        // already swap-removed from pending via `removePending`.
        std.debug.assert(!self.isPending(url_hash));
        self.failed_hashes[self.failed_count] = url_hash;
        self.failed_count += 1;
    }

    // -------------------------------------------------------------------------
    // Enqueue + drain
    // -------------------------------------------------------------------------

    /// Spawn a background fetch for `url` if there is capacity, the URL is
    /// not already pending, and it has not previously failed.
    ///
    /// Returns `true` iff a fetch was actually launched. The caller does
    /// not need to inspect the return — the next frame's `drain` will
    /// surface the result either way. The bool is provided for test
    /// assertions and for telemetry callers.
    ///
    /// `url` is duplicated into `gpa` and ownership of the copy is
    /// transferred to the background task, which frees it on completion.
    pub fn enqueueIfRoom(self: *Self, url: []const u8, key: ImageKey) bool {
        std.debug.assert(url.len > 0);
        std.debug.assert(url.len <= MAX_URL_LENGTH);

        if (self.isFailed(key.source_hash)) return false;
        if (self.isPending(key.source_hash)) return false;
        if (!self.hasRoom()) return false;

        // The source slice often lives in the layout arena which is reset
        // each frame; the background task outlives the frame, so we copy.
        const url_owned = self.gpa.dupe(u8, url) catch return false;

        self.addPending(key.source_hash);

        // Fire-and-forget. The task fetches, decodes, and pushes a result
        // into `result_queue`. On window close / cancel-group fire, the
        // backoff sleep observes cancellation and the task unwinds.
        self.fetch_group.async(
            self.io,
            loadFromUrl,
            .{ self.io, self.gpa, url_owned, key, &self.result_queue },
        );
        return true;
    }

    /// Drain the result queue into the atlas. Call once per frame in
    /// `beginFrame` — after the atlas has done its own per-frame reset.
    ///
    /// Non-blocking: `Io.Queue.get` with timeout `0` returns immediately
    /// with whatever is buffered. Capped at `MAX_IMAGE_LOAD_RESULTS` per
    /// frame so a sudden burst of completions cannot stretch a frame.
    pub fn drain(self: *Self) void {
        // Local drain buffer — keeps the queue lock held for as little as
        // possible, then we operate on the snapshot lock-free.
        var drain_buffer: [MAX_IMAGE_LOAD_RESULTS]ImageLoadResult = undefined;
        const count = self.result_queue.get(self.io, &drain_buffer, 0) catch return;
        std.debug.assert(count <= MAX_IMAGE_LOAD_RESULTS);

        for (drain_buffer[0..count]) |*result| {
            switch (result.*) {
                .loaded => |*loaded| {
                    self.removePending(loaded.key.source_hash);
                    // Cache decoded pixels into the atlas. `cacheRgba`
                    // copies, so freeing `loaded.pixels` afterwards is
                    // safe (and required — the queue is the owner).
                    _ = self.image_atlas.*.cacheRgba(
                        loaded.key,
                        loaded.width,
                        loaded.height,
                        loaded.pixels,
                    ) catch {};
                    loaded.allocator.free(loaded.pixels);
                    loaded.pixels = &.{};
                },
                .failed => |failed| {
                    // Remove from pending BEFORE adding to failed — the
                    // invariant in `addFailed` is that a URL is never in
                    // both sets at once.
                    self.removePending(failed.key.source_hash);
                    self.addFailed(failed.key.source_hash);
                },
            }
        }
    }
};


// =============================================================================
// Public API
// =============================================================================

/// Load image from source
pub fn load(allocator: std.mem.Allocator, source: ImageSource, io: std.Io) LoadError!DecodedImage {
    return switch (source) {
        .embedded => |data| loadFromMemory(allocator, data),
        .path => |path| loadFromPath(allocator, path, io),
        .url => LoadError.UnsupportedSource, // URLs are loaded asynchronously via loadFromUrl + Io.Queue.
        .data => |data| loadFromImageData(allocator, data),
    };
}

/// Load image from raw bytes (PNG, JPEG, etc.)
pub const loadFromMemory = backend.loadFromMemory;

/// Load image from file path
/// Note: Not supported on WASM - use embedded images or URL loading instead.
pub const loadFromPath = if (is_wasm)
    loadFromPathUnsupported
else
    loadFromPathNative;

fn loadFromPathUnsupported(_: std.mem.Allocator, _: []const u8, _: std.Io) LoadError!DecodedImage {
    return LoadError.UnsupportedSource;
}

fn loadFromPathNative(allocator: std.mem.Allocator, path: []const u8, io: std.Io) LoadError!DecodedImage {
    // Read file into memory (Zig 0.16: std.Io.Dir replaces std.fs).
    const data = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        path,
        allocator,
        .limited(256 * 1024 * 1024),
    ) catch |err| {
        return switch (err) {
            error.FileNotFound => LoadError.FileNotFound,
            error.OutOfMemory => LoadError.OutOfMemory,
            else => LoadError.IoError,
        };
    };
    defer allocator.free(data);

    return loadFromMemory(allocator, data);
}

/// Load from pre-decoded ImageData (just converts format if needed)
pub fn loadFromImageData(allocator: std.mem.Allocator, data: ImageData) LoadError!DecodedImage {
    const rgba = data.toRgba(allocator) catch return LoadError.OutOfMemory;
    return DecodedImage{
        .width = data.width,
        .height = data.height,
        .pixels = rgba,
        .allocator = allocator,
    };
}

// =============================================================================
// Async URL Loading (Phase 4)
// =============================================================================

/// Fetch an image from a URL and decode it.
///
/// Designed to run as a background task via `Io.Group.async`. On completion
/// (success or failure), pushes an `ImageLoadResult` into the provided queue
/// for the frame loop to drain and cache.
///
/// The `url_owned` slice is freed after use — caller must allocate it with
/// the same allocator passed here.
pub fn loadFromUrl(
    io: std.Io,
    allocator: std.mem.Allocator,
    url_owned: []const u8,
    key: ImageKey,
    queue: *std.Io.Queue(ImageLoadResult),
) std.Io.Cancelable!void {
    // Clean up the owned URL copy when done, regardless of outcome.
    defer allocator.free(url_owned);

    std.debug.assert(url_owned.len > 0);
    std.debug.assert(url_owned.len <= MAX_URL_LENGTH);

    // Per-task PRNG for backoff jitter — seeded from the URL hash so each
    // concurrent fetch picks independent jitter without needing a shared
    // thread-safe global RNG. Determinism-per-URL is a feature, not a bug:
    // reproducible timing in tests.
    var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(0, url_owned));
    const rng = prng.random();

    const body = fetchWithRetry(io, allocator, url_owned, rng) catch {
        pushFailed(io, queue, key);
        return;
    };
    defer allocator.free(body);

    const decoded = loadFromMemory(allocator, body) catch {
        // Decode errors are deterministic — retrying a corrupt response body
        // wastes bandwidth. Surface as `.failed` immediately.
        pushFailed(io, queue, key);
        return;
    };

    // Transfer decoded pixels to the queue. The consumer owns freeing them.
    queue.putOneUncancelable(io, .{ .loaded = .{
        .key = key,
        .width = decoded.width,
        .height = decoded.height,
        .pixels = decoded.pixels,
        .allocator = decoded.allocator,
    } }) catch {
        // Queue closed — free the pixels we would have transferred.
        decoded.allocator.free(decoded.pixels);
    };
}

/// Fetch with bounded exponential backoff and jitter.
///
/// Returns the response body on success. On `error.Permanent` the caller
/// should surface `.failed` immediately. On `error.Transient` after all
/// attempts are exhausted, also surface `.failed`. Cancellation (window
/// close / cancel group fire) propagates through the backoff sleep as
/// `std.Io.Cancelable` — callers must handle both error unions.
///
/// Retry budget (hardcoded — see Task 4.5b rationale above):
///   attempt 0: fetch, on transient fail sleep ~500ms ± jitter
///   attempt 1: fetch, on transient fail sleep ~1000ms ± jitter
///   attempt 2: fetch, on any fail give up
fn fetchWithRetry(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    rng: std.Random,
) (FetchError || std.Io.Cancelable)![]u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(url.len <= MAX_URL_LENGTH);
    comptime std.debug.assert(MAX_FETCH_ATTEMPTS > 0);

    var attempt: u32 = 0;
    while (attempt < MAX_FETCH_ATTEMPTS) : (attempt += 1) {
        if (fetchHttpBody(io, allocator, url)) |body| {
            return body;
        } else |err| switch (err) {
            // Permanent errors fail fast — no retry, no backoff.
            error.Permanent => return error.Permanent,
            // Transient: retry if budget remains, otherwise propagate.
            error.Transient => {
                // Last attempt exhausted — no point sleeping just to give up.
                if (attempt + 1 >= MAX_FETCH_ATTEMPTS) return error.Transient;

                // Exponential base: 500ms, 1000ms, 2000ms, ...
                // Shift amount is bounded by MAX_FETCH_ATTEMPTS (3) — well
                // below the u6 limit for a u64 shift.
                std.debug.assert(attempt < 63);
                const base_ms: u64 = BASE_BACKOFF_MS << @as(u6, @intCast(attempt));

                // Symmetric jitter in [-JITTER_PERCENT%, +JITTER_PERCENT%].
                const jitter_range_ms: u64 = base_ms * JITTER_PERCENT / 100;
                const jitter_signed: i64 = rng.intRangeAtMost(
                    i64,
                    -@as(i64, @intCast(jitter_range_ms)),
                    @as(i64, @intCast(jitter_range_ms)),
                );
                const sleep_ms: i64 = @as(i64, @intCast(base_ms)) + jitter_signed;
                // base_ms ≥ 500, jitter at most ±125 at first attempt, so
                // sleep_ms is always well above zero. Assert so a future
                // tweak to the constants trips here instead of panicking
                // inside Duration.
                std.debug.assert(sleep_ms > 0);

                // Cancellation propagates here: if the window closes or a
                // cancel group fires during backoff, the task unwinds
                // cleanly with Cancelable and the URL is never retried.
                // `.awake` is the monotonic clock (CLOCK_MONOTONIC on Linux,
                // CLOCK_UPTIME_RAW on macOS) — backoff timing must not jump
                // when the wall clock is adjusted by NTP or sysadmin.
                try io.sleep(std.Io.Duration.fromMilliseconds(sleep_ms), .awake);
            },
        }
    }
    // Loop exits only via explicit return — the final iteration either
    // returned a body or returned `error.Transient`.
    unreachable;
}

/// HTTP GET helper — fetches the response body into an allocated buffer.
/// Returns owned bytes; caller must free with `allocator`.
///
/// All errors are classified as `Transient` (retry-worthy) or `Permanent`
/// (deterministic failure). See Task 4.5b retry policy above.
fn fetchHttpBody(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
) FetchError![]u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(url.len <= MAX_URL_LENGTH);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    // Malformed URL — user programming error, never retry.
    const uri = std.Uri.parse(url) catch return error.Permanent;

    // Initial request build. Errors here span OOM (permanent), unsupported
    // URI scheme (permanent), and connect failures (transient). Zig's
    // http.Client rolls them into one error set so we classify by tag.
    var req = client.request(.GET, uri, .{}) catch |err| return classifyRequestError(err);
    defer req.deinit();

    // Sending the request body fails transiently on I/O — retry.
    req.sendBodiless() catch return error.Transient;

    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| return classifyReceiveHeadError(err);

    // HTTP status classification:
    //   2xx → success
    //   4xx → client error, deterministic — permanent
    //   5xx → server error, possibly recovering — transient
    //   other (1xx, 3xx leaked through, unknown) → permanent (unexpected)
    const status_code: u32 = @intFromEnum(response.head.status);
    if (status_code >= 200 and status_code < 300) {
        // Fall through to body read.
    } else if (status_code >= 500 and status_code < 600) {
        return error.Transient;
    } else {
        return error.Permanent;
    }

    var transfer_buffer: [8192]u8 = undefined;
    var body_reader = response.reader(&transfer_buffer);

    // Body read failures are transient (I/O / truncated stream). OOM and
    // size-limit breaches are permanent — a body larger than our cap won't
    // shrink on retry.
    const body = body_reader.allocRemaining(allocator, .limited(MAX_URL_RESPONSE_BYTES)) catch |err| {
        return switch (err) {
            error.OutOfMemory, error.StreamTooLong => error.Permanent,
            else => error.Transient,
        };
    };
    return body;
}

/// Classify errors returned by `http.Client.request()`.
///
/// OOM and programmer-error variants (unsupported URI scheme, invalid auth)
/// are permanent; everything else is treated as transient network-layer.
fn classifyRequestError(err: anyerror) FetchError {
    return switch (err) {
        error.OutOfMemory,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.UriHostTooLong,
        => error.Permanent,
        // ConnectionRefused, TemporaryNameServerFailure, NetworkUnreachable,
        // TlsInitializationFailed, and friends — all transient by nature.
        else => error.Transient,
    };
}

/// Classify errors returned by `Request.receiveHead()`.
///
/// Malformed HTTP responses and redirect-related failures are deterministic
/// protocol errors — the server won't suddenly start speaking HTTP correctly
/// on retry. Connection failures during header read are transient.
fn classifyReceiveHeadError(err: anyerror) FetchError {
    return switch (err) {
        error.HttpHeadersInvalid,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpHeadersOversize,
        error.UnsupportedUriScheme,
        error.OutOfMemory,
        => error.Permanent,
        // ReadFailed, WriteFailed, connection errors — transient.
        else => error.Transient,
    };
}

/// Push a failure result into the queue. Silently drops if queue is closed.
fn pushFailed(io: std.Io, queue: *std.Io.Queue(ImageLoadResult), key: ImageKey) void {
    queue.putOneUncancelable(io, .{ .failed = .{ .key = key } }) catch {};
}

// =============================================================================
// Utility Functions
// =============================================================================

pub const ImageFormat = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
};

/// Detect image format from magic bytes
pub fn detectFormat(data: []const u8) ?ImageFormat {
    if (data.len < 8) return null;

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (std.mem.eql(u8, data[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' })) {
        return .png;
    }

    // JPEG: FF D8 FF
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return .jpeg;
    }

    // GIF: GIF87a or GIF89a
    if (data.len >= 6 and std.mem.eql(u8, data[0..3], "GIF")) {
        return .gif;
    }

    // WebP: RIFF....WEBP
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) {
        return .webp;
    }

    // BMP: BM
    if (data.len >= 2 and data[0] == 'B' and data[1] == 'M') {
        return .bmp;
    }

    return null;
}

/// Create a solid color image (useful for placeholders)
pub fn createSolidColor(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) LoadError!DecodedImage {
    const pixels = allocator.alloc(u8, width * height * 4) catch
        return LoadError.OutOfMemory;

    var i: usize = 0;
    while (i < width * height) : (i += 1) {
        const offset = i * 4;
        pixels[offset + 0] = r;
        pixels[offset + 1] = g;
        pixels[offset + 2] = b;
        pixels[offset + 3] = a;
    }

    return DecodedImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Create a checkerboard pattern (useful for transparency indication)
pub fn createCheckerboard(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    cell_size: u32,
) LoadError!DecodedImage {
    const pixels = allocator.alloc(u8, width * height * 4) catch
        return LoadError.OutOfMemory;

    const light = [4]u8{ 255, 255, 255, 255 };
    const dark = [4]u8{ 204, 204, 204, 255 };

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const cell_x = x / cell_size;
            const cell_y = y / cell_size;
            const is_light = (cell_x + cell_y) % 2 == 0;
            const color = if (is_light) light else dark;

            const offset = (y * width + x) * 4;
            @memcpy(pixels[offset..][0..4], &color);
        }
    }

    return DecodedImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// Bookkeeping-only tests: pending/failed sets, queue fixup, capacity caps.
// We do NOT exercise `enqueueIfRoom` end-to-end here because that spawns a
// real `Io.Group.async` task which would need a backing thread pool and a
// reachable HTTP endpoint. End-to-end coverage lives in the integration
// tests for `runtime/render.zig`.

test "ImageLoader: pending and failed bookkeeping" {
    const testing = std.testing;
    const ImageAtlas = atlas.ImageAtlas;

    // Set up a real ImageAtlas — `ImageLoader` borrows it for `drain`.
    var image_atlas: ImageAtlas = try ImageAtlas.init(testing.allocator, 1.0, testing.io);
    defer image_atlas.deinit();

    var loader: ImageLoader = undefined;
    loader.initInPlace(testing.io, testing.allocator, &image_atlas);
    defer loader.deinit();

    try testing.expect(!loader.isPending(0xdead));
    try testing.expect(!loader.isFailed(0xdead));
    try testing.expect(loader.hasRoom());

    // Direct manipulation through the internal API to avoid spawning an
    // actual fetch — we are exercising the bookkeeping only.
    loader.addPending(0xdead);
    try testing.expect(loader.isPending(0xdead));
    try testing.expectEqual(@as(u32, 1), loader.pending_count);

    loader.addPending(0xbeef);
    try testing.expectEqual(@as(u32, 2), loader.pending_count);

    // Swap-remove keeps the other entry intact.
    loader.removePending(0xdead);
    try testing.expect(!loader.isPending(0xdead));
    try testing.expect(loader.isPending(0xbeef));
    try testing.expectEqual(@as(u32, 1), loader.pending_count);

    // Failed set: idempotent on duplicate.
    loader.removePending(0xbeef);
    loader.addFailed(0xbeef);
    loader.addFailed(0xbeef);
    try testing.expect(loader.isFailed(0xbeef));
    try testing.expectEqual(@as(u32, 1), loader.failed_count);
}

test "ImageLoader: hasRoom flips at capacity" {
    const testing = std.testing;
    const ImageAtlas = atlas.ImageAtlas;

    var image_atlas: ImageAtlas = try ImageAtlas.init(testing.allocator, 1.0, testing.io);
    defer image_atlas.deinit();

    var loader: ImageLoader = undefined;
    loader.initInPlace(testing.io, testing.allocator, &image_atlas);
    defer loader.deinit();

    // Fill the pending set right up to the cap. Use distinct hashes so the
    // dedup assertion in `addPending` does not trip.
    var i: u64 = 0;
    while (i < MAX_PENDING_IMAGE_LOADS) : (i += 1) {
        try testing.expect(loader.hasRoom());
        loader.addPending(0x1000 + i);
    }
    try testing.expect(!loader.hasRoom());

    // Removing one frees a slot.
    loader.removePending(0x1000);
    try testing.expect(loader.hasRoom());
}

test "ImageLoader: fixupQueue restores the queue pointer after a copy" {
    const testing = std.testing;
    const ImageAtlas = atlas.ImageAtlas;

    var image_atlas: ImageAtlas = try ImageAtlas.init(testing.allocator, 1.0, testing.io);
    defer image_atlas.deinit();

    // Build a loader at one address …
    var stack_loader: ImageLoader = undefined;
    stack_loader.initInPlace(testing.io, testing.allocator, &image_atlas);

    // … then copy by value to its "real" home. This is the exact pattern
    // `Gooey.initOwned` exercises before calling `fixupImageLoadQueue`.
    const heap_loader = try testing.allocator.create(ImageLoader);
    defer testing.allocator.destroy(heap_loader);
    heap_loader.* = stack_loader;

    // After the copy the queue's internal pointer references
    // `stack_loader.result_buffer`, which is about to go out of scope.
    // `fixupQueue` must rebind it to the new address.
    heap_loader.fixupQueue();

    // Pair-assertion: the queue's backing storage now lives inside
    // `heap_loader`, not the stack-allocated original.
    const queue_buffer_addr = @intFromPtr(&heap_loader.result_buffer);
    const stack_buffer_addr = @intFromPtr(&stack_loader.result_buffer);
    try testing.expect(queue_buffer_addr != stack_buffer_addr);

    heap_loader.deinit();
}
