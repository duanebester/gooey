//! Generic asset cache skeleton — PR 1 seed for the future `Asset(T)` system.
//!
//! Rationale: PR 1 extracts `ImageLoader` as the prototype shape for every
//! subsequent subsystem extraction (SVG in PR 2, fonts after that, audio,
//! shaders, …). All of those subsystems share the same architecture:
//!
//!   1. A fixed-capacity slot map keyed by a hash.
//!   2. A producer-consumer `Io.Queue` for completed loads.
//!   3. A pending-set + failed-set for de-dup and short-circuit.
//!   4. An `Io.Group` lifetime envelope that gets cancelled at teardown.
//!
//! Rather than copy-paste this shape across N modules, the long-term plan
//! (cleanup item #9, see `docs/architectural-cleanup-plan.md` and
//! `docs/cleanup-implementation-plan.md` PR 1) is a generic
//! `AssetCache(T, cap)` that each subsystem composes once.
//!
//! This file is intentionally a **skeleton**: it pins down the type shape
//! and the public surface so PR 2 onwards can fill in the body without
//! redesigning. `ImageLoader` (in `loader.zig`) is the working
//! implementation; once SVG migrates onto this skeleton in PR 2 the
//! pattern is validated against two callers and we can fold `ImageLoader`
//! down to a thin wrapper around `AssetCache(DecodedImage, ...)`.
//!
//! Why ship a skeleton now instead of waiting?
//!
//! - The shape of the type (in particular the comptime parameters and the
//!   trait the inner `T` must satisfy) is the load-bearing decision. Pinning
//!   it here forces the SVG and image extractions to converge instead of
//!   each inventing its own slightly-different shape.
//! - PR 1 must respect the "no public-API regressions" rule
//!   (`docs/cleanup-implementation-plan.md` §1). A future swap from a
//!   bespoke `ImageLoader` to `AssetCache(Image, ...)` is a public-API
//!   change in spirit; documenting the target up front lets reviewers
//!   spot drift early.
//! - It costs almost nothing — no runtime code, no behaviour change.
//!
//! Non-goals for this PR:
//!
//! - Wiring `ImageLoader` through `AssetCache`. That is PR 2's job, after
//!   the SVG callsite proves the trait shape on a second consumer.
//! - Eviction / LRU. Cleanup item #9 explicitly defers that to the
//!   follow-up "asset retention policy" issue. The skeleton documents
//!   the hook but does not implement it.

const std = @import("std");

// =============================================================================
// Asset trait — what every cached `T` must look like
// =============================================================================
//
// The cache is generic over `T`, but `T` is not arbitrary. It must:
//
//   1. Have a stable comptime `Key` type that hashes to `u64` for de-dup.
//   2. Expose `pub fn deinit(self: *T) void` so the cache can free entries
//      on eviction or teardown.
//   3. Be safely move-constructible — the cache stores `T` by value in a
//      fixed-capacity backing array and may swap-remove on eviction.
//
// `verifyAssetType` is a comptime check that PR 2 will call from
// `AssetCache(T, cap)` to surface trait violations at the point of
// instantiation rather than deep inside the cache body. Keeping it as a
// free function (not buried inside the generic) makes the diagnostic
// readable: the error message points at the trait, not at line 437 of a
// generic body.

/// Compile-time validation that `T` is a valid asset type.
///
/// Called from `AssetCache(T, cap)` instantiation. Failures are
/// `@compileError` with a message that names the missing requirement.
/// Call sites are expected to be one-liners: `comptime verifyAssetType(T);`
pub fn verifyAssetType(comptime T: type) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct" and info != .@"union") {
            @compileError("AssetCache: T must be a struct or tagged union, got " ++ @typeName(T));
        }

        if (!@hasDecl(T, "Key")) {
            @compileError("AssetCache: T must declare a `pub const Key = ...` type, missing on " ++ @typeName(T));
        }

        if (!@hasDecl(T, "deinit")) {
            @compileError("AssetCache: T must declare `pub fn deinit(self: *T) void`, missing on " ++ @typeName(T));
        }
    }
}

// =============================================================================
// AssetCache — generic fixed-capacity cache
// =============================================================================

/// Configuration options for an `AssetCache` instantiation.
///
/// Passed as a single comptime struct (per `CLAUDE.md` §9: named arguments
/// via `options: struct`) so adding future knobs (LRU policy, async drain
/// strategy, eviction hooks) does not break call sites.
pub const Options = struct {
    /// Hard cap on simultaneously-cached assets. The cache fails fast at
    /// capacity rather than evicting silently — eviction policy lives in
    /// the follow-up "asset retention policy" issue.
    capacity: u32,

    /// Hard cap on in-flight async loads.
    pending_capacity: u32,

    /// Hard cap on remembered failed-load keys per session.
    /// See `ImageLoader.MAX_FAILED_IMAGE_LOADS` for the rationale: a
    /// 60Hz render loop without this cap will rate-limit the user's IP
    /// on a single 404.
    failed_capacity: u32,
};

/// Generic asset cache — **skeleton only** in PR 1.
///
/// PR 2 (SVG consolidation) will fill this in by:
///
///   1. Lifting the slot-map / pending-set / failed-set / `Io.Queue` /
///      `Io.Group` body out of `ImageLoader`.
///   2. Replacing the bespoke `ImageLoader` storage with
///      `AssetCache(DecodedImage, .{ ... })`.
///   3. Replacing the bespoke `SvgRasterCache` storage similarly.
///
/// In the meantime this stub documents the public surface so the two
/// consumers (image, svg) cannot drift before the merge.
pub fn AssetCache(comptime T: type, comptime options: Options) type {
    comptime verifyAssetType(T);
    comptime std.debug.assert(options.capacity > 0);
    comptime std.debug.assert(options.pending_capacity > 0);
    comptime std.debug.assert(options.failed_capacity > 0);

    return struct {
        const Self = @This();

        // The per-instance trait validation is comptime — re-asserting
        // here documents the contract at the type definition site as
        // well as at the instantiation site (`CLAUDE.md` §3).
        comptime {
            verifyAssetType(T);
        }

        // ---------------------------------------------------------------------
        // Public API surface — bodies arrive in PR 2
        // ---------------------------------------------------------------------

        /// Initialize in place at the struct's final heap address.
        ///
        /// Will be `noinline` once implemented (`CLAUDE.md` §14) — the
        /// struct embeds large fixed-capacity arrays whose stack temp
        /// would blow the WASM 1MB budget if a caller's frame combined
        /// with this one.
        pub fn initInPlace(self: *Self, io: std.Io, gpa: std.mem.Allocator) void {
            _ = self;
            _ = io;
            _ = gpa;
            @compileError("AssetCache.initInPlace: skeleton only, body lands in PR 2 (SVG consolidation)");
        }

        /// Cancel in-flight loads and free cached entries.
        pub fn deinit(self: *Self) void {
            _ = self;
            @compileError("AssetCache.deinit: skeleton only, body lands in PR 2");
        }

        /// `true` iff the keyed asset is currently cached.
        pub fn contains(self: *const Self, key: T.Key) bool {
            _ = self;
            _ = key;
            @compileError("AssetCache.contains: skeleton only, body lands in PR 2");
        }

        /// `true` iff a background load for `key` is in flight.
        pub fn isPending(self: *const Self, key_hash: u64) bool {
            _ = self;
            _ = key_hash;
            @compileError("AssetCache.isPending: skeleton only, body lands in PR 2");
        }

        /// `true` iff a previous load for `key` failed this session.
        pub fn isFailed(self: *const Self, key_hash: u64) bool {
            _ = self;
            _ = key_hash;
            @compileError("AssetCache.isFailed: skeleton only, body lands in PR 2");
        }

        /// Drain completed loads into the cache. Called once per frame.
        pub fn drain(self: *Self) void {
            _ = self;
            @compileError("AssetCache.drain: skeleton only, body lands in PR 2");
        }
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// Skeleton-level tests only: confirm the trait validator behaves as
// advertised. Body-level tests (slot map, drain semantics, cancellation
// propagation) ship with PR 2.

test "verifyAssetType accepts a well-formed asset" {
    const Good = struct {
        pub const Key = u64;
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
        value: u32,
    };
    comptime verifyAssetType(Good);
}

test "Options validates capacities at comptime" {
    // Sanity: a typical instantiation compiles. The body of `AssetCache`
    // is a `@compileError` skeleton, so we cannot call methods — but
    // referencing the type is enough to exercise the comptime asserts
    // on `Options`.
    const Good = struct {
        pub const Key = u64;
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
        value: u32,
    };
    const Cache = AssetCache(Good, .{
        .capacity = 32,
        .pending_capacity = 16,
        .failed_capacity = 64,
    });
    // Touching a decl forces comptime evaluation of the surrounding type.
    _ = @sizeOf(Cache);
}
