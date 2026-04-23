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
