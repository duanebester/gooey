//! Render-thread blocking mutex for Gooey.
//!
//! ## Why this shim still exists (Phase 5, option 3)
//!
//! Zig 0.16 introduced `std.Io.Mutex`, which requires threading an `Io`
//! instance into every `.lock()` / `.unlock()` call. Phase 5 of the
//! `std.Io` migration (see `docs/zig-0.16-io-migration.md`) migrated every
//! non-render mutex in the framework to `std.Io.Mutex`:
//!
//!   • `ImageAtlas.mutex` — stores `io` on the struct
//!   • `SvgAtlas.mutex`   — stores `io` on the struct
//!   • `TextSystem.shape_cache_mutex` / `glyph_cache_mutex` — ditto
//!   • `CodeEditorState.generateUniqueId` counter — now a plain atomic
//!
//! The one remaining holdout is `Window.render_mutex` on macOS. It is
//! locked from the CVDisplayLink callback thread, which is spawned and
//! owned by CoreVideo — not by Gooey — and therefore has no natural path
//! to an `Io` instance. Option 3 from the migration doc is to keep the
//! platform mutex exclusively for render synchronisation, which is what
//! this file provides.
//!
//! ## Backing primitives
//!
//!   • macOS / Darwin  — `os_unfair_lock`  (what the old std.Thread.Mutex used)
//!   • Linux / POSIX   — `pthread_mutex_t` (libc is always linked on Linux)
//!   • WASM            — no-op (single-threaded; no render thread at all)
//!
//! ## Why not `std.atomic.Mutex`?
//!
//! It only exposes `tryLock` (a single CAS) and `unlock` — no blocking
//! `lock`. A spin-wait wrapper around `tryLock` would burn CPU on any
//! contention, which is unacceptable for render-thread synchronisation
//! where the critical section may briefly block behind GPU command
//! submission.

const std = @import("std");
const builtin = @import("builtin");

/// A blocking mutual-exclusion lock for render-thread synchronisation.
///
/// **Use `std.Io.Mutex` for everything else.** This shim exists solely
/// because the CVDisplayLink thread on macOS has no `Io` instance. See
/// the module-level docs above for the full rationale.
///
/// Default-initialised to the unlocked state (API-compatible with the
/// former `std.Thread.Mutex`).
pub const Mutex = switch (builtin.os.tag) {
    .macos => DarwinMutex,
    .linux => PosixMutex,
    else => if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64)
        NoOpMutex
    else
        PosixMutex,
};

// ---------------------------------------------------------------------------
// Darwin: os_unfair_lock
// ---------------------------------------------------------------------------

const DarwinMutex = struct {
    oul: std.c.os_unfair_lock = .{},

    pub fn lock(self: *DarwinMutex) void {
        std.c.os_unfair_lock_lock(&self.oul);
    }

    pub fn unlock(self: *DarwinMutex) void {
        std.c.os_unfair_lock_unlock(&self.oul);
    }

    pub fn tryLock(self: *DarwinMutex) bool {
        return std.c.os_unfair_lock_trylock(&self.oul);
    }
};

// ---------------------------------------------------------------------------
// POSIX: pthread_mutex_t
// ---------------------------------------------------------------------------

const PosixMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn tryLock(self: *PosixMutex) bool {
        const rc = std.c.pthread_mutex_trylock(&self.inner);
        if (rc == .SUCCESS) return true;
        std.debug.assert(rc == .BUSY);
        return false;
    }
};

// ---------------------------------------------------------------------------
// WASM / single-threaded: no-op
// ---------------------------------------------------------------------------

const NoOpMutex = struct {
    pub fn lock(_: *NoOpMutex) void {}
    pub fn unlock(_: *NoOpMutex) void {}
    pub fn tryLock(_: *NoOpMutex) bool {
        return true;
    }
};
