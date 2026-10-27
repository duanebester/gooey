//! Render-thread blocking mutex for Gooey.
//!
//! ## Why this shim exists (option 3 in the migration doc)
//!
//! `std.Io.Mutex` requires threading an `Io` instance into every
//! `.lock()` / `.unlock()` call. Every non-render mutex in the framework
//! uses `std.Io.Mutex` (see `docs/zig-0.16-io-migration.md`):
//!
//!   • `ImageAtlas.mutex` — stores `io` on the struct
//!   • `SvgAtlas.mutex`   — stores `io` on the struct
//!   • `TextSystem.shape_cache_mutex` / `glyph_cache_mutex` — ditto
//!   • `CodeEditorState.generateUniqueId` counter — a plain atomic
//!
//! The one exception is `Window.render_mutex` on macOS. It is
//! locked from the CVDisplayLink callback thread, which is spawned and
//! owned by CoreVideo — not by Gooey — and therefore has no natural path
//! to an `Io` instance. This file provides a platform mutex used
//! exclusively for render synchronisation.
//!
//! ## Backing primitives
//!
//!   • macOS / Darwin  — `os_unfair_lock`  (the primitive behind Zig 0.15's `std.Thread.Mutex`)
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
/// Default-initialised to the unlocked state (API-compatible with Zig
/// 0.15's `std.Thread.Mutex`).
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
    owner: Owner = .{},

    pub fn lock(self: *DarwinMutex) void {
        std.c.os_unfair_lock_lock(&self.oul);
        self.owner.claim();
    }

    pub fn unlock(self: *DarwinMutex) void {
        self.owner.release();
        std.c.os_unfair_lock_unlock(&self.oul);
    }

    pub fn tryLock(self: *DarwinMutex) bool {
        if (!std.c.os_unfair_lock_trylock(&self.oul)) return false;
        self.owner.claim();
        return true;
    }

    pub fn heldByCurrentThread(self: *const DarwinMutex) bool {
        return self.owner.isCurrentThread();
    }
};

// ---------------------------------------------------------------------------
// POSIX: pthread_mutex_t
// ---------------------------------------------------------------------------

const PosixMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    owner: Owner = .{},

    pub fn lock(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
        self.owner.claim();
    }

    pub fn unlock(self: *PosixMutex) void {
        self.owner.release();
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn tryLock(self: *PosixMutex) bool {
        const rc = std.c.pthread_mutex_trylock(&self.inner);
        if (rc == .SUCCESS) {
            self.owner.claim();
            return true;
        }
        std.debug.assert(rc == .BUSY);
        return false;
    }

    pub fn heldByCurrentThread(self: *const PosixMutex) bool {
        return self.owner.isCurrentThread();
    }
};

// ---------------------------------------------------------------------------
// WASM / single-threaded: no-op
// ---------------------------------------------------------------------------

const NoOpMutex = struct {
    /// One thread, so "held" is exactly "locked and not yet unlocked".
    held: bool = false,

    pub fn lock(self: *NoOpMutex) void {
        std.debug.assert(!self.held);
        self.held = true;
    }
    pub fn unlock(self: *NoOpMutex) void {
        std.debug.assert(self.held);
        self.held = false;
    }
    pub fn tryLock(self: *NoOpMutex) bool {
        if (self.held) return false;
        self.held = true;
        return true;
    }
    pub fn heldByCurrentThread(self: *const NoOpMutex) bool {
        return self.held;
    }
};

// ---------------------------------------------------------------------------
// Ownership
// ---------------------------------------------------------------------------

/// The thread holding a mutex, so a caller can tell "I already hold this
/// render lock" (an input handler runs inside its window's lock) from "a
/// render thread holds it". Written only by the holder, after locking and
/// before unlocking; other threads read it only to learn it is not theirs.
const Owner = struct {
    thread_id: std.atomic.Value(std.Thread.Id) = .init(owner_none),

    /// No thread: platform thread ids are never zero.
    const owner_none: std.Thread.Id = 0;

    fn claim(self: *Owner) void {
        const current = std.Thread.getCurrentId();
        std.debug.assert(current != owner_none);
        std.debug.assert(self.thread_id.load(.monotonic) == owner_none);
        self.thread_id.store(current, .monotonic);
    }

    fn release(self: *Owner) void {
        std.debug.assert(self.isCurrentThread());
        self.thread_id.store(owner_none, .monotonic);
    }

    fn isCurrentThread(self: *const Owner) bool {
        return self.thread_id.load(.monotonic) == std.Thread.getCurrentId();
    }
};

// ---------------------------------------------------------------------------
// Exclusion set
// ---------------------------------------------------------------------------

/// The render mutexes one thread takes to exclude every render thread from
/// state they all read, such as the shared text system during a font reload.
///
/// `acquire` skips mutexes the caller already holds: an input handler runs
/// inside its own window's render lock, and locking it again would abort an
/// `os_unfair_lock`. `release` unlocks only what `acquire` locked, so the
/// handler still holds its window afterwards.
///
/// Deadlock freedom: a render thread holds at most its own window's mutex and
/// never waits for another, and only one thread (the platform's main thread)
/// ever holds a set. So no two threads can each hold one mutex of a set while
/// waiting for another.
pub const ExclusionSet = struct {
    acquired: [mutex_count_max]*Mutex = undefined,
    acquired_count: u32 = 0,

    /// Matches `WindowRegistry.MAX_WINDOWS`: one render mutex per window.
    pub const mutex_count_max: u32 = 32;

    pub fn acquire(self: *ExclusionSet, mutexes: []const *Mutex) void {
        std.debug.assert(self.acquired_count == 0);
        std.debug.assert(mutexes.len <= mutex_count_max);

        for (mutexes) |mutex| {
            if (mutex.heldByCurrentThread()) continue;
            mutex.lock();
            self.acquired[self.acquired_count] = mutex;
            self.acquired_count += 1;
        }

        std.debug.assert(self.acquired_count <= mutexes.len);
        for (mutexes) |mutex| std.debug.assert(mutex.heldByCurrentThread());
    }

    /// Unlock in reverse acquisition order.
    pub fn release(self: *ExclusionSet) void {
        std.debug.assert(self.acquired_count <= mutex_count_max);

        while (self.acquired_count > 0) {
            self.acquired_count -= 1;
            self.acquired[self.acquired_count].unlock();
        }

        std.debug.assert(self.acquired_count == 0);
    }
};

test "ExclusionSet keeps every other thread out and leaves the caller's own lock held" {
    // Goal: the invariant `Window.setFont` relies on. While the set is held,
    // no other thread can run a critical section under any member mutex, so a
    // render frame never observes a reload in progress. A mutex the caller
    // already held (its window's lock, taken by input dispatch) is not locked
    // twice and is still held afterwards. Methodology: a render thread loops
    // over its own window's mutex and records any time it sees the reload flag
    // set; the main thread holds window A's mutex like an input handler, then
    // repeatedly acquires the set {A, B}, raises the flag, does some work, and
    // lowers it. A set that skipped B would let the render thread see the flag.
    if (builtin.single_threaded) return error.SkipZigTest;

    const Shared = struct {
        window_a: Mutex = .{},
        window_b: Mutex = .{},
        reloading: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),
        frames: std.atomic.Value(u32) = .init(0),
        frames_during_reload: std.atomic.Value(u32) = .init(0),

        fn renderThread(shared: *@This()) void {
            while (!shared.stop.load(.acquire)) {
                shared.window_b.lock();
                if (shared.reloading.load(.acquire)) {
                    _ = shared.frames_during_reload.fetchAdd(1, .monotonic);
                }
                _ = shared.frames.fetchAdd(1, .monotonic);
                shared.window_b.unlock();
            }
        }
    };

    var shared: Shared = .{};
    const render_thread = try std.Thread.spawn(.{}, Shared.renderThread, .{&shared});

    shared.window_a.lock();
    const reload_count: u32 = 200;
    var reload: u32 = 0;
    while (reload < reload_count) : (reload += 1) {
        var exclusion: ExclusionSet = .{};
        exclusion.acquire(&.{ &shared.window_a, &shared.window_b });
        try std.testing.expectEqual(@as(u32, 1), exclusion.acquired_count);
        shared.reloading.store(true, .release);
        var spin: u32 = 0;
        while (spin < 2_000) : (spin += 1) std.atomic.spinLoopHint();
        shared.reloading.store(false, .release);
        exclusion.release();

        // Let the render thread take window B between reloads.
        const frames_before = shared.frames.load(.monotonic);
        while (shared.frames.load(.monotonic) == frames_before) std.atomic.spinLoopHint();
    }

    try std.testing.expect(shared.window_a.heldByCurrentThread());
    try std.testing.expect(!shared.window_b.heldByCurrentThread());
    shared.window_a.unlock();

    shared.stop.store(true, .release);
    render_thread.join();

    try std.testing.expect(shared.frames.load(.monotonic) >= reload_count);
    try std.testing.expectEqual(@as(u32, 0), shared.frames_during_reload.load(.monotonic));
}
