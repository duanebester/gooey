# Zig 0.16 Changes — Research Notes

> Companion to [`zig-0.16-io-migration.md`](./zig-0.16-io-migration.md).
> That document tracks Gooey's migration plan and what we've already done;
> this one is a flatter reference of the 0.16 churn we hit (and the bits we
> haven't hit yet but probably will).
>
> Source: [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html).
> Upgraded from 0.15.2 → 0.16.0. 8 months of work, 244 contributors, 1183 commits.

---

## Table of Contents

1. [The headliner: I/O as an Interface](#1-the-headliner-io-as-an-interface)
2. [`std.Io` primitives in detail](#2-stdio-primitives-in-detail)
3. [Sync primitives migration table](#3-sync-primitives-migration-table)
4. [Entropy / random](#4-entropy--random)
5. [Time](#5-time)
6. [File system](#6-file-system)
7. [Networking](#7-networking)
8. [Process: spawn, run, replace](#8-process-spawn-run-replace)
9. ["Juicy Main"](#9-juicy-main)
10. [Environment variables and CLI args become non-global](#10-environment-variables-and-cli-args-become-non-global)
11. [Reader / Writer churn (the rest of writergate)](#11-reader--writer-churn-the-rest-of-writergate)
12. [`std.io.fixedBufferStream` is gone](#12-stdiofixedbufferstream-is-gone)
13. [`fs.Dir.readFileAlloc` and friends](#13-fsdirreadfilealloc-and-friends)
14. [Atomic / temporary files](#14-atomic--temporary-files)
15. [`fs.path.relative` became pure](#15-fspathrelative-became-pure)
16. [`File.Stat`: access time is optional](#16-filestat-access-time-is-optional)
17. [Selective directory walking](#17-selective-directory-walking)
18. [Allocator changes](#18-allocator-changes)
19. [`std.Thread.Pool` removed](#19-stdthreadpool-removed)
20. [`@Type` split into individual builtins](#20-type-split-into-individual-builtins)
21. [Language: switch, packed, vectors, etc.](#21-language-switch-packed-vectors-etc)
22. [Lazy field analysis & reworked type resolution](#22-lazy-field-analysis--reworked-type-resolution)
23. [Compile-time errors that didn't exist before](#23-compile-time-errors-that-didnt-exist-before)
24. [Misc. stdlib renames and removals](#24-misc-stdlib-renames-and-removals)
25. [Build system](#25-build-system)
26. [Compiler / Linker / Fuzzer](#26-compiler--linker--fuzzer)
27. [Toolchain: LLVM 21, libc updates](#27-toolchain-llvm-21-libc-updates)
28. [Gooey-specific takeaways](#28-gooey-specific-takeaways)

---

## 1. The headliner: I/O as an Interface

The big one. `std.Io` is the `Allocator` pattern applied to I/O and
concurrency. **Anything that potentially blocks control flow or introduces
nondeterminism is now owned by the I/O interface.**

Implementations shipping in 0.16:

| Implementation | Status                       | Notes                                                               |
| -------------- | ---------------------------- | ------------------------------------------------------------------- |
| `Io.Threaded`  | **Feature-complete**, tested | Thread pool. `-fsingle-threaded` skips concurrency/cancelation      |
| `Io.Evented`   | **Experimental**, WIP        | Userspace stack switching (M:N, green threads, stackful coroutines) |
| `Io.Uring`     | Proof-of-concept             | Linux io_uring. Lacks networking, error handling, test coverage     |
| `Io.Kqueue`    | Proof-of-concept             | Just enough to avoid a common bug in other async runtimes           |
| `Io.Dispatch`  | Proof-of-concept             | Grand Central Dispatch (macOS)                                      |
| `Io.failing`   | Test fixture                 | Simulates a system supporting no operations                         |

Same code works identically across backends. Swap only the `Io` construction
in `main()`.

When upgrading code without an `Io` instance handy:

```zig
var threaded: Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

This is the equivalent of reaching for `std.heap.page_allocator`. **Prefer
to accept an `Io` parameter or store one on a context struct.** `main`
should generally be responsible for constructing the `Io` instance.

In tests: use `std.testing.io` (mirrors `std.testing.allocator`).

---

## 2. `std.Io` primitives in detail

Overview of what's on the `Io` namespace:

| Primitive                                      | Purpose                                                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `Future(T)`                                    | Function-level abstraction. `io.async(fn, .{args})` returns one. `await` / `cancel`               |
| `Group`                                        | Manages many tasks sharing a lifetime. O(1) overhead for spawning N tasks. `await` / `cancel` all |
| `Queue(T)`                                     | Many-producer, many-consumer, thread-safe channel. Configurable buffer. Suspends when empty/full  |
| `Select`                                       | Wait until one or more tasks complete. Higher-level than `Batch`                                  |
| `Batch`                                        | Lower-level concurrency at the `Operation` layer. More efficient and portable than `Future`       |
| `Clock` / `Duration` / `Timestamp` / `Timeout` | Type-safe time units                                                                              |

### `io.async` vs `io.concurrent`

- **`io.async(fn, .{args})`** — expresses _operational independence_. The
  call _can_ be done independently from other logic. **Infallible.** It is
  legal for `Io` implementations to implement `async` simply by directly
  calling the function before returning.
- **`io.concurrent(fn, .{args})`** — expresses that the operation _must_
  be done concurrently for correctness. Necessarily allocates (because
  that's the nature of doing things simultaneously). Can fail with
  `error.ConcurrencyUnavailable`.

Both return a `Future(T)` with `await(io)` and `cancel(io)`.

### Cancelation (one l, allegedly)

> Lo! Lest one learn a lone release lesson, let proclaim: "cancelation"
> should seriously only be spelt thusly (single "l"). Let not evil, godless
> liars lead afoul.
>
> — Andrew Kelley, 0.16.0 release notes

`Future`, `Group`, and `Batch` all support cancelation. When requested,
acknowledged cancelation requests cause I/O operations to return
`error.Canceled`. **Most I/O operations now have `error.Canceled` in their
error sets.** Even `Io.Threaded` supports cancelation by sending a signal
to a thread, causing blocking syscalls to return `EINTR`, then re-checking.

Three ways to handle `error.Canceled`, in order of common-ness:

1. **Propagate it.**
2. **Recancel and don't propagate** — `io.recancel()` rearms the cancelation
   request so the next check will detect and acknowledge.
3. **Make it unreachable** — `io.swapCancelProtection()`.

Only the logic that made the cancelation request can soundly ignore an
`error.Canceled`.

The canonical pattern:

```zig
var foo_future = io.async(foo, .{args});
defer if (foo_future.cancel(io)) |resource| resource.deinit() else |_| {}

var bar_future = io.async(bar, .{args});
defer if (bar_future.cancel(io)) |resource| resource.deinit() else |_| {}

const foo_result = try foo_future.await(io);
const bar_result = try bar_future.await(io);
```

If `foo` doesn't return a freed resource, simplify to `_ = foo.cancel(io) catch {}`
(or just `_ = foo.cancel(io)` for `void`-returning fns). The `cancel` is
necessary because it releases the async task resource even on success/error.

You rarely need to call `io.checkCancel` explicitly — it's baked into the
error sets of cancelable operations. The primary use case is long-running
CPU-bound tasks.

### `Group` example: sleep sort

```zig
var group: Io.Group = .init;
defer group.cancel(io);

for (&array) |elem| group.async(io, sleepAppend, .{ io, &sorted, &index, elem });

try group.await(io);
```

### `Future` vs `Batch` — when to use which

- **`Future`** — flexible, ergonomic, function-level. Allocates task memory.
  `error.ConcurrencyUnavailable` (when using `concurrent`) or unwanted
  blocking (when using `async`) can occur in more circumstances.
- **`Batch`** — lower-level, operates at the `Operation` layer. Efficient and
  portable but harder to abstract around, especially if you need to run
  logic between operations.

Currently `Operation`-eligible (works with `Batch` + `operateTimeout`):

- `FileReadStreaming`
- `FileWriteStreaming`
- `DeviceIoControl`
- `NetReceive`

Eventually most file system and networking will migrate to `Operation`.

> Generally, if you're trying to write optimal, reusable software, `Batch`
> is the way to go if you simply need to do several operations at once.
> Otherwise, you can always use the `Future` APIs if that would essentially
> require you to reinvent futures. Or you can start with `Future` APIs and
> then optimize by reworking some stuff to use `Batch` later.

---

## 3. Sync primitives migration table

Sync primitives must be migrated so they integrate with the chosen `Io`
implementation. With `Io.Threaded`, a contended mutex blocks the thread.
With `Io.Evented`, it switches stacks.

| Old                          | New                                                    |
| ---------------------------- | ------------------------------------------------------ |
| `std.Thread.ResetEvent`      | `std.Io.Event`                                         |
| `std.Thread.WaitGroup`       | `std.Io.Group`                                         |
| `std.Thread.Futex`           | `std.Io.Futex`                                         |
| `std.Thread.Mutex`           | `std.Io.Mutex`                                         |
| `std.Thread.Condition`       | `std.Io.Condition`                                     |
| `std.Thread.Semaphore`       | `std.Io.Semaphore`                                     |
| `std.Thread.RwLock`          | `std.Io.RwLock`                                        |
| `std.once`                   | **Removed** — avoid global vars or hand-roll the logic |
| `std.Thread.Mutex.Recursive` | **Removed**                                            |

Lock-free primitives (`std.atomic.Value`) do _not_ require `Io`.

---

## 4. Entropy / random

Random number generation is now an `Io` operation.

```zig
// std.crypto.random.bytes
var buffer: [123]u8 = undefined;
io.random(&buffer);

// std.Random interface
const rng_impl: std.Random.IoSource = .{ .io = io };
const rng = rng_impl.interface();

// posix.getrandom
var buffer: [64]u8 = undefined;
io.random(&buffer);
```

Two flavors:

- **`io.random(buffer)`** — may use stored RNG state in process memory.
  Cryptographic strength depends on the `Io` implementation.
- **`io.randomSecure(buffer)`** — _always_ makes a syscall. No fallback;
  returns `error.EntropyUnavailable` on problems. Use this if you want
  CSPRNG state out of process memory.

`std.Options.crypto_always_getrandom` and `std.Options.crypto_fork_safety`
are gone — they're now distinct `Io` APIs.

---

## 5. Time

| Old                  | New                    |
| -------------------- | ---------------------- |
| `std.time.Instant`   | `std.Io.Timestamp`     |
| `std.time.Timer`     | `std.Io.Timestamp`     |
| `std.time.timestamp` | `std.Io.Timestamp.now` |

Clock resolution is now queryable (and may fail). This lets timeout/clock
error sets drop `error.Unexpected` and `error.ClockUnsupported` — they're
treated as having infinite resolution, detectable by calling
`Clock.resolution` first.

For wall time: `std.Io.Clock.real.now(io).toSeconds()` (replaces
`std.time.timestamp()`).

For monotonic time: `std.Io.Timestamp.now(io, .awake)` — uses
`CLOCK_UPTIME_RAW` on macOS, `CLOCK_MONOTONIC` on Linux. NTP/wall-clock
adjustments can no longer break timing math.

The `{D}` format specifier is removed in favor of `Io.Duration`'s format
method:

```zig
writer.print("{f}", .{std.Io.Duration{ .nanoseconds = ns }});
```

---

## 6. File system

**All `fs` APIs migrated to `Io`.** Most call sites get a mechanical change:

```zig
file.close(io);
dir.openFile(io, path, .{});
```

Top-level moves:

| Old                 | New                                              |
| ------------------- | ------------------------------------------------ |
| `fs.Dir`            | `std.Io.Dir`                                     |
| `fs.File`           | `std.Io.File`                                    |
| `fs.cwd`            | `std.Io.Dir.cwd`                                 |
| `fs.path`           | `std.Io.Dir.path` (deprecated alias still works) |
| `fs.max_path_bytes` | `std.Io.Dir.max_path_bytes`                      |
| `fs.max_name_bytes` | `std.Io.Dir.max_name_bytes`                      |
| `fs.realpath`       | `std.Io.Dir.realPathFileAbsolute`                |
| `fs.realpathAlloc`  | `std.Io.Dir.realPathFileAbsoluteAlloc`           |

Self-exe stuff moved to `std.process`:

- `fs.openSelfExe` → `std.process.openExecutable`
- `fs.selfExePathAlloc` → `std.process.executablePathAlloc`
- `fs.selfExePath` → `std.process.executablePath`
- `fs.selfExeDirPath` → `std.process.executableDirPath`
- `fs.selfExeDirPathAlloc` → `std.process.executableDirPathAlloc`
- `fs.Dir.setAsCwd` → `std.process.setCurrentDir`

Renames:

- `fs.Dir.makeDir` → `createDir`
- `fs.Dir.makePath` → `createDirPath`
- `fs.Dir.makeOpenDir` → `createDirPathOpen`
- `fs.Dir.atomicSymLink` → `symLinkAtomic`
- `fs.Dir.chmod` → `setPermissions`
- `fs.Dir.chown` → `setOwner`
- `fs.Dir.rename` — now accepts two `Dir` parameters (plus `Io`)

File mode/permissions consolidated:

- `fs.File.Mode`, `PermissionsWindows`, `PermissionsUnix` →
  `std.Io.File.Permissions`
- `fs.File.default_mode` → `std.Io.File.Permissions.default_file`
- `fs.File.mode` → `stat().permissions.toMode`
- `fs.File.chmod` / `chown` → `setPermissions` / `setOwner`
- `fs.File.updateTimes` → `setTimestamps` / `setTimestampsNow`
- `fs.File.setEndPos` / `getEndPos` → `setLength` / `length`

Read/write split into streaming vs positional:

| Old                                | New                              |
| ---------------------------------- | -------------------------------- |
| `fs.File.read`/`readv`             | `std.Io.File.readStreaming`      |
| `fs.File.pread`/`preadv`           | `std.Io.File.readPositional`     |
| `fs.File.preadAll`                 | `std.Io.File.readPositionalAll`  |
| `fs.File.write`/`writev`           | `std.Io.File.writeStreaming`     |
| `fs.File.pwrite`/`pwritev`         | `std.Io.File.writePositional`    |
| `fs.File.writeAll`                 | `std.Io.File.writeStreamingAll`  |
| `fs.File.pwriteAll`                | `std.Io.File.writePositionalAll` |
| `fs.File.copyRange`/`copyRangeAll` | `std.Io.File.writer`             |

Seek/position moved onto `Reader`/`Writer`:

- `fs.File.seekTo` / `seekBy` / `seekFromEnd` → `std.Io.File.Reader.seekTo`,
  `Reader.seekBy`, `Writer.seekTo`
- `fs.File.getPos` → `Reader.logicalPos` or `Writer.logicalPos`

Removed with no replacement (mostly the `Z`/`W`/`Wasi` Z-string variants):
`fs.realpathZ/W/W2`, `fs.makeDirAbsoluteZ`, `fs.deleteDirAbsoluteZ`,
`fs.openDirAbsoluteZ`, `fs.renameAbsoluteZ`, `fs.renameZ`,
`fs.deleteTreeAbsolute`, `fs.symLinkAbsoluteW`, all the corresponding
`Dir.*Z`/`*W`/`*Wasi` methods, and `fs.File.isCygwinPty`. Also the
`adaptToNewApi` / `adaptFromNewApi` shims.

Added: `Io.Dir.hardLink`, `Io.Dir.Reader`, `Io.Dir.setFilePermissions`,
`Io.Dir.setFileOwner`, `Io.File.NLink`, `Io.Dir.renamePreserve` (rename
without replacing destination).

Error set changes:

- `error.RenameAcrossMountPoints` → `error.CrossDevice`
- `error.NotSameFileSystem` → `error.CrossDevice`
- `error.SharingViolation` → `error.FileBusy`
- `error.EnvironmentVariableNotFound` → `error.EnvironmentVariableMissing`
- `std.Io.Dir.rename` now returns `error.DirNotEmpty` rather than
  `error.PathAlreadyExists`

---

## 7. Networking

**All `net` APIs migrated to `Io`.** New `std.Io.net` namespace.

`std.http.Client` is one of the most visible beneficiaries. Demo from the
release notes:

```zig
var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
defer http_client.deinit();

var request = try http_client.request(.HEAD, .{
    .scheme = "http",
    .host = .{ .percent_encoded = host_name.bytes },
    .port = 80,
    .path = .{ .percent_encoded = "/" },
}, .{});
defer request.deinit();

try request.sendBodiless();

var redirect_buffer: [1024]u8 = undefined;
const response = try request.receiveHead(&redirect_buffer);
```

Properties this gives you for free:

- DNS queries fan out to all configured nameservers asynchronously.
- TCP connection attempts race (happy eyeballs).
- First successful connection cancels all the rest, including DNS queries.
- Works with `-fsingle-threaded` (operations happen sequentially).
- On Windows: no `ws2_32.dll` dependency.

Caveats:

- `Io.Evented` does not yet implement networking.
- `Io.net` currently lacks a way to do non-IP networking.

Added: `Io.net.Socket.createPair`.

---

## 8. Process: spawn, run, replace

Spawning a child process:

```zig
// Old
var child = std.process.Child.init(argv, gpa);
child.stdin_behavior = .Pipe;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;
try child.spawn(io);

// New
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
    .stdout = .pipe,
    .stderr = .pipe,
});
```

Capturing output:

```zig
// Old
const result = std.process.Child.run(allocator, io, .{...});
// New
const result = std.process.run(allocator, io, .{...});
```

Replacing the current process image:

```zig
// Old
const err = std.process.execv(arena, argv);
// New
const err = std.process.replace(io, .{ .argv = argv });
```

Memory locking moved to `process` and got typesafe flags:

```zig
// Old
std.posix.PROT.READ | std.posix.PROT.WRITE
// New
.{ .READ = true, .WRITE = true }

// Old
try std.posix.mlock();
try std.posix.mlock2(slice, std.posix.MLOCK_ONFAULT);
try std.posix.mlockall(slice, std.posix.MCL_CURRENT|std.posix.MCL_FUTURE);
// New
try std.process.lockMemory(slice, .{});
try std.process.lockMemory(slice, .{ .on_fault = true });
try std.process.lockMemoryAll(.{ .current = true, .future = true });
```

Current dir API renamed (because in the std lib `Dir` means an open handle,
not a path; "get" and "working" are superfluous):

```zig
// Old
std.process.getCwd(buffer)
std.process.getCwdAlloc(allocator)
// New
std.process.currentPath(io, buffer)
std.process.currentPathAlloc(io, allocator)
```

---

## 9. "Juicy Main"

`pub fn main` now takes an optional `process.Init` parameter:

```zig
pub const Init = struct {
    minimal: Minimal,
    arena: *std.heap.ArenaAllocator,  // Permanent storage for the process. Threadsafe.
    gpa: Allocator,                   // Default GPA, with leak checking in Debug. Threadsafe.
    io: Io,                           // Default Io implementation. Leak checking in Debug.
    environ_map: *Environ.Map,        // Initialized with gpa. Not threadsafe.
    preopens: Preopens,               // void on non-WASI

    pub const Minimal = struct {
        environ: Environ,
        args: Args,
    };
};
```

Three valid shapes for `main`:

1. **No parameter** — legal, but no env / argv access.
2. **`std.process.Init.Minimal`** — argv and environ in raw form.
3. **`std.process.Init`** — pre-initialized goodies.

Example:

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // ...

    try std.Io.File.stdout().writeStreamingAll(io, "Hello, world!\n");
}
```

---

## 10. Environment variables and CLI args become non-global

Globals are gone. **Environment variables are only available in `main`.**

Old footguns (gone):

- `std.os.environ` — was meant to be equivalent to C's `environ`, but
  impossible to populate in a library that doesn't link libc.
- `std.os.argv` — same problem.

Migration:

- `std.os.argv` → `init.minimal.args.vector` (raw `[]const [*:0]const u8`)
- `init.minimal.args.toSlice(arena)` — convenience slice
- `init.minimal.args.iterate()` — iterator API

Functions needing env vars should accept a `*const process.Environ.Map`
parameter rather than reaching for a global.

---

## 11. Reader / Writer churn (the rest of writergate)

The 0.15.x writer rewrite kept rolling in 0.16. Affected:

- `std.io` → `std.Io`
- `std.Io.GenericReader` → `std.Io.Reader`
- `std.Io.AnyReader` → `std.Io.Reader`
- `std.Io.GenericWriter` — **removed**
- `std.Io.AnyWriter` — **removed**
- `std.Io.null_writer` — **removed**
- `std.Io.CountingReader` — **removed**

LEB128:

- `std.leb.readUleb128` → `std.Io.Reader.takeLeb128`
- `std.leb.readIleb128` → `std.Io.Reader.takeLeb128`

`File.Reader` / `File.Writer` byte-sink methods (`writeAll`, `readAlloc`,
etc.) **relocated onto `.interface`**:

```zig
writer.interface.writeAll(...)
reader.interface.allocRemaining(...)
```

`File.Writer.flush` stays on the outer type — it forwards to the interface
flush and surfaces any latched error.

`std.Io.Writer.Allocating` gained an `alignment: std.mem.Alignment` field
(runtime-known alignment for the "raw" Allocator API variants).

Format namespace:

- `std.fmt.Formatter` → `std.fmt.Alt`
- `std.fmt.format` → `std.Io.Writer.print`
- `std.fmt.FormatOptions` → `std.fmt.Options`
- `std.fmt.bufPrintZ` → `std.fmt.bufPrintSentinel`

---

## 12. `std.io.fixedBufferStream` is gone

```zig
// Reading
var fbs = std.io.fixedBufferStream(data);
const reader = fbs.reader();
// ⬇️
var reader: std.Io.Reader = .fixed(data);

// Writing
var fbs = std.io.fixedBufferStream(buffer);
const writer = fbs.writer();
// ⬇️
var writer: std.Io.Writer = .fixed(buffer);
```

`fbs.getWritten()` → `writer.buffered()`.

---

## 13. `fs.Dir.readFileAlloc` and friends

```zig
// Old
const contents = try std.fs.cwd().readFileAlloc(allocator, file_name, 1234);
// New
const contents = try std.Io.Dir.cwd().readFileAlloc(io, file_name, allocator, .limited(1234));
```

**Behavior change**: when the limit is _reached_, it now returns the error.
Error renamed `FileTooBig` → `StreamTooLong`.

```zig
// Old
const contents = try file.readToEndAlloc(allocator, 1234);
// New
var file_reader = file.reader(io, &.{});
const contents = try file_reader.interface.allocRemaining(allocator, .limited(1234));
```

---

## 14. Atomic / temporary files

Mostly motivated by moving `std.crypto.random` below the `std.Io.VTable`,
plus integrating with Linux's `O_TMPFILE` (with a side rant in the release
notes about how `O_TMPFILE` is "almost very good" but actually nearly
useless because `linkat()` doesn't support `AT_REPLACE`).

```zig
// Old
var buffer: [1024]u8 = undefined;
var atomic_file = try dest_dir.atomicFile(io, dest_path, .{
    .permissions = actual_permissions,
    .write_buffer = &buffer,
});
defer atomic_file.deinit();
// ... write to atomic_file.file_writer ...
try atomic_file.flush();
try atomic_file.renameIntoPlace();

// New
var atomic_file = try dest_dir.createFileAtomic(io, dest_path, .{
    .permissions = actual_permissions,
    .make_path = true,
    .replace = true,
});
defer atomic_file.deinit(io);

var buffer: [1024]u8 = undefined; // Used only when direct fd-to-fd is unavailable.
var file_writer = atomic_file.file.writer(io, &buffer);
// ... write to file_writer ...
try file_writer.flush();
try atomic_file.replace(io); // Or set .replace = false above and call .link() instead.
```

Also new: `std.Io.File.hardLink` (Linux-only — needed to materialize an
`O_TMPFILE` fd without replacement semantics).

---

## 15. `fs.path.relative` became pure

`relative`, `relativeWindows`, `relativePosix` no longer query the OS
internally. Pass the CWD path and (optionally) an environment map:

```zig
// Old
const rel = try std.fs.path.relative(gpa, from, to);
defer gpa.free(rel);

// New
const cwd_path = try std.process.currentPathAlloc(io, gpa);
defer gpa.free(cwd_path);
const rel = try std.fs.path.relative(gpa, cwd_path, environ_map, from, to);
defer gpa.free(rel);
```

Other `fs.path` Windows-correctness fixes — all functions handle UNC,
"rooted", and drive-relative paths more consistently. See
[ziglang/zig#25993](https://github.com/ziglang/zig/issues/25993).

API renames:

- `windowsParsePath` / `diskDesignator` / `diskDesignatorWindows` →
  `parsePath` / `parsePathWindows` / `parsePathPosix`
- Added `getWin32PathType`
- `componentIterator` / `ComponentIterator.init` can no longer fail.

---

## 16. `File.Stat`: access time is optional

```zig
// Old
stat.atime  // i128
// New
stat.atime orelse return error.FileAccessTimeUnavailable  // ?i128
```

Filesystems struggle to keep `atime` updated since reads become writes;
ZFS in particular is observed to not report it from `statx`.

`setTimestamps` got a more flexible API that mirrors what's on POSIX
(independent `UTIME_OMIT` / `UTIME_NOW` for atime/mtime):

```zig
// Old
try atomic_file.file_writer.file.setTimestamps(io, src_stat.atime, src_stat.mtime);
// New
try atomic_file.file_writer.file.setTimestamps(io, .{
    .access_timestamp = .init(src_stat.atime),
    .modify_timestamp = .init(src_stat.mtime),
});
```

---

## 17. Selective directory walking

`std.Io.Dir.walk` doesn't support skipping directories; if you want to
prune subtrees during recursion, use `walkSelectively`:

```zig
var walker = try dir.walkSelectively(gpa);
defer walker.deinit();

while (try walker.next(io)) |entry| {
    if (failsFilter(entry)) continue;
    if (entry.kind == .directory) {
        try walker.enter(io, entry);
    }
    // ...
}
```

This avoids redundant open/close syscalls on skipped dirs. Also added:
`Walker.Entry.depth()`, `Walker.leave()`, `SelectiveWalker.leave()` for
bailing out partway through.

---

## 18. Allocator changes

- **`heap.ArenaAllocator` is now thread-safe and lock-free.** Comparable
  perf to the previous version single-threaded; slight speedup vs.
  `ThreadSafeAllocator`-wrapped variant up to ~7 contending threads. Same
  treatment is planned for `heap.DebugAllocator`.
- **`heap.ThreadSafe` allocator removed.** "The only reasonable way to
  implement `ThreadSafeAllocator`, which wraps an underlying `Allocator`,
  is with a mutex, which necessarily requires an `Io` instance and is
  generally inefficient." Practically every allocator that wants thread
  safety can be lock-free. Anti-pattern, removed.
- **`SegmentedList` removed.**
- **`meta.declList` removed.**

### Migration to "Unmanaged" containers continues

`Unmanaged` was always more versatile; the managed/unmanaged distinction
is being collapsed.

- `ArrayHashMap`, `AutoArrayHashMap`, `StringArrayHashMap` — removed.
- `AutoArrayHashMapUnmanaged` → `array_hash_map.Auto`
- `StringArrayHashMapUnmanaged` → `array_hash_map.String`
- `ArrayHashMapUnmanaged` → `array_hash_map.Custom`
- Added: `heap.MemoryPoolUnmanaged`, `MemoryPoolAlignedUnmanaged`,
  `MemoryPoolExtraUnmanaged`.
- `PriorityDequeue` no longer has an `Allocator` field.
- `PriorityQueue` no longer has an `Allocator` field.

`PriorityDequeue` rename sweep:

| Old               | New             |
| ----------------- | --------------- |
| `init`            | `.empty`        |
| `add`             | `push`          |
| `addSlice`        | `pushSlice`     |
| `addUnchecked`    | `pushUnchecked` |
| `removeMinOrNull` | `popMin`        |
| `removeMin`       | `popMin`        |
| `removeMaxOrNull` | `popMax`        |
| `removeMax`       | `popMax`        |
| `removeIndex`     | `popIndex`      |

`PriorityQueue` rename sweep:

| Old            | New             |
| -------------- | --------------- |
| `init`         | `initContext`   |
| `add`          | `push`          |
| `addUnchecked` | `pushUnchecked` |
| `addSlice`     | `pushSlice`     |
| `remove`       | `pop`           |
| `removeOrNull` | `pop`           |
| `removeIndex`  | `popIndex`      |

Also: `BitSet` and `EnumSet`'s `initEmpty` / `initFull` are replaced with
decl literals (presumably `.empty` / `.full`).

---

## 19. `std.Thread.Pool` removed

Replaced by `std.Io.async` / `std.Io.Group.async`.

```zig
// Old
fn doAllTheWork(pool: *std.Thread.Pool) void {
    var wg: std.Thread.WaitGroup = .{};
    pool.spawnWg(wg, doSomeWork, .{ pool, &wg, first });
    wg.wait();
}

// New
fn doAllTheWork(io: std.Io) void {
    var g: std.Io.Group = .init;
    errdefer g.cancel(io);
    g.async(io, doSomeWork, .{ io, &g, first });
    try g.await(io);
}
```

**Important**: any `Thread.Mutex` / `Thread.Condition` / `Thread.ResetEvent`
in code being migrated must also be converted to its `Io` equivalent
(`Io.Mutex`, etc.) for correctness.

For complex usages where two or more tasks must synchronize, `async` may
not be appropriate — consult the docs for `Io.async` / `Io.concurrent`.

---

## 20. `@Type` split into individual builtins

Long-accepted [proposal #10710](https://github.com/ziglang/zig/issues/10710).
`@Type` is gone, replaced by 8 typed builtins (plus existing `@Vector`).

```zig
@EnumLiteral() type
@Int(signedness, bits) type
@Tuple(field_types) type
@Pointer(size, attrs, Element, sentinel) type
@Fn(param_types, param_attrs, ReturnType, attrs) type
@Struct(layout, BackingInt, field_names, field_types, field_attrs) type
@Union(layout, ArgType, field_names, field_types, field_attrs) type
@Enum(TagInt, mode, field_names, field_values) type
```

Common upgrades:

```zig
@Type(.enum_literal)                                              // ⬇️ @EnumLiteral()
@Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })       // ⬇️ @Int(.unsigned, 10)
```

`@Struct`/`@Union`/`@Fn` use a "struct of arrays" style — when you want
defaults for all elements, use `&@splat(.{})`.

Notable absences:

- **No `@Float`** — only 5 runtime float types; trivial userland (or
  `std.meta.Float`).
- **No `@Array`** — use `[len]Elem` or `[len:s]Elem`.
- **No `@Opaque`** — write `opaque {}`.
- **No `@Optional`** — write `?T`.
- **No `@ErrorUnion`** — write `E!T`.
- **No `@ErrorSet`** — error sets can no longer be reified at all. Declare
  with `error{ ... }` syntax.

It is also no longer possible to reify tuple types with `comptime` fields.

---

## 21. Language: switch, packed, vectors, etc.

### switch

- `packed struct` and `packed union` may now be used as switch prong items
  (compared by backing integer, like equality comparisons).
- Decl literals and other result-type-requiring expressions
  (e.g., `@enumFromInt`) may now be used as switch prong items.
- Union tag captures are now allowed for all prongs, not just `inline`.
- Switch prongs may contain errors not in the error set, if they
  `=> comptime unreachable`.
- Switch prong captures may no longer all be discarded.
- Switching on `void` no longer requires an `else` prong unconditionally.
- Lots of one-possible-value-type switching bugs fixed.

### Packed types

- **Equality comparisons on packed unions now work directly** (no struct wrapper needed).
- **Forbidden: unused bits in packed unions.** All fields must have the
  same `@bitSizeOf` as a backing integer type.
- **Forbidden: pointers in packed structs and unions.** Implements
  [#24657](https://github.com/ziglang/zig/issues/24657). Use `usize` +
  `@ptrFromInt` / `@intFromPtr`.
- **Allowed: explicit backing integer on packed unions** via
  `packed union(T)` syntax.
- **Forbidden: enum/packed types with inferred backing types in extern
  contexts.** Implements
  [#24714](https://github.com/ziglang/zig/issues/24714). The fix is to
  add an explicit `(T)` backing type.

### Vectors

- **Runtime vector indexes are forbidden.** Coerce to an array first:
  ```zig
  for (0..vector_len) |i| _ = vector[i];
  // ⬇️
  const vec_info = @typeInfo(@TypeOf(vector)).vector;
  const array: [vec_info.len]vec_info.child = vector;
  for (&array) |elem| _ = elem;
  ```
- **Vectors and arrays no longer support in-memory coercion.** If you
  were `@ptrCast`ing between them, use coercion instead. Coercing
  `anyerror![4]i32` → `anyerror!@Vector(4, i32)` requires unwrapping the
  error first.

### Numeric / float ergonomics

- Small integer types **coerce to floats** automatically when all values
  fit. (e.g., `u24` → `f32` is implicit; `u25` → `f32` still requires
  `@floatFromInt`.) Determined by significand width.
- **Unary float builtins forward result type** —
  `const x: f64 = @sqrt(@floatFromInt(N))` works now.
- **`@floor`, `@ceil`, `@round`, `@trunc` can convert float → int.**
  `@intFromFloat` is now redundant with `@trunc` and is **deprecated**.

### Forbid trivial local address returns

```zig
fn foo() *i32 {
    var x: i32 = 1234;
    return &x;  // error: returning address of expired local variable 'x'
}
```

The compiler now flags syntactic patterns that obviously lower to
`return undefined`.

---

## 22. Lazy field analysis & reworked type resolution

Two related compiler reworks:

- **Lazy field analysis** — using a type as a namespace no longer forces
  analysis of its fields. `*T` no longer requires `T` to be resolved.
  This was specifically motivated by `std.Io` — using `std.Io.Writer` in
  any way previously pulled in the full `std.Io` vtable.
- **Reworked type resolution** — generally _more_ permissive than before.
  Most code keeps working; some previously-rejected dependency cycles are
  now accepted. But certain patterns are now (correctly) rejected, e.g.:
  ```zig
  const S = struct {
      foo: [*]align(@alignOf(@This())) u8,  // dependency loop
  };
  ```
- **Pointers to comptime-only types are no longer comptime-only.**
  `*comptime_int` is a runtime type; you just can't dereference it at
  runtime. Useful for passing `[]const std.builtin.Type.StructField` to
  runtime code and reading `.name` per element.
- **Explicitly-aligned pointer types are now distinct from
  naturally-aligned ones.** `*u8` and `*align(1) u8` were previously the
  literal same type; now they're different but coerce to one another.
- **Simplified dependency loop rules** — a few new cases are now loops,
  but error reporting is dramatically improved.
- **Zero-bit tuple fields no longer implicitly comptime.** A 0.14 bug
  reverted; almost entirely non-breaking unless you read
  `is_comptime` from `@typeInfo`.

---

## 23. Compile-time errors that didn't exist before

A growing list. As of 0.16:

- Returning the address of a trivially-local variable (see above).
- Non-`extern` enum / packed struct / packed union with implicit backing
  type used in `extern` context (see above).
- Pointers in packed types (see above).
- Runtime indexing of vectors (see above).
- New dependency-loop cases from reworked type resolution.

> More compile errors of this nature are planned.

---

## 24. Misc. stdlib renames and removals

`mem`:

- Introduced cut functions: `cut`, `cutPrefix`, `cutSuffix`, `cutScalar`,
  `cutLast`, `cutLastScalar`.
- Renamed "index of" → "find". Concept names in `std.mem`:
  - **find** — return index of substring
  - **pos** — starting index parameter
  - **last** — search from the end
  - **linear** — simple for-loop rather than fancy algorithm
  - **scalar** — substring is a single element

Other:

- `math.sign` returns the smallest integer type that fits possible values.
- `tar.extract` sanitizes path traversal.
- Compress: lzma, lzma2, xz updated to `Io.Reader` / `Io.Writer`.
- **Added**: deflate compression (~10% faster than zlib at default level).
- **DynLib**: removed Windows support. Use `LoadLibraryExW` /
  `GetProcAddress` directly.
- **`fs.getAppDataDir` removed.** Too opinionated for stdlib. Third-party
  alternative: `known-folders`.
- **`builtin.subsystem` removed.** Detection was flaky and the actual
  subsystem isn't known until link time.
- **`Target.SubSystem` moved** to `zig.Subsystem` (deprecated alias kept
  for `exe.subsystem = .Windows`).
- **`ucontext_t` and related types/functions removed.** `ucontext.h` is
  deprecated in POSIX and not in musl. Roll your own for signal handling
  needs.

WASI/`Preopens` consolidation:

```zig
// Old
const wasi_preopens: std.fs.wasi.Preopens = try .preopensAlloc(arena);
// New
const preopens: std.process.Preopens = try .init(arena);
// Or via Juicy Main: init.preopens
```

Crypto adds:

- AES-SIV, AES-GCM-SIV (nonce-misuse-resistant).
- Ascon-AEAD, Ascon-Hash, Ascon-CHash (NIST SP 800-232 lightweight crypto).

`std.posix` and `std.os.windows` — most "medium-level" wrappers are
removed. **Go higher (`std.Io`) or go lower (`std.posix.system`).**

Stack traces overhauled:

- `std.debug.captureStackTrace` → `captureCurrentStackTrace`
- `dumpStackTraceFromBase` → `dumpCurrentStackTrace`
- `walkStackWindows` → `captureCurrentStackTrace`
- `writeStackTraceWindows` → `writeCurrentStackTrace`
- `std.debug.StackIterator` is now internal (no longer `pub`).
- `std.debug.SelfInfo` is the platform debug-info abstraction, overridable
  via `@import("root").debug.SelfInfo` for freestanding targets.
- `std.debug.writeStackTrace` accepts `Io.Terminal` rather than a writer.
- New `StackUnwindOptions` controls `first_address`, optional `context`,
  and whether to fall back to `allow_unsafe_unwind`.

---

## 25. Build system

### Project-local package overrides

```bash
zig build --fork=/path/to/local/package
```

Matches by `name` + `fingerprint` from `build.zig.zon`, ignoring `version`.
Resolves before fetching. Errors if the path doesn't match anything.

### Packages fetched into project-local directory

Packages now land in a `zig-pkg/` directory next to `build.zig`, not
`$GLOBAL_ZIG_CACHE/p/$HASH`. After fetch + filter, the canonical tarball
gets stored in the global cache as a `.tar.gz`.

`zig build` now fails on dependencies missing `fingerprint` or with
string-style `name`. `ZIG_BTRFS_WORKAROUND` env var is gone (upstream
Linux fixed long ago).

### Unit test timeouts

```bash
zig build test --test-timeout 500ms
```

Forcibly kills + restarts the test process per `test` block on timeout.
Real time, not CPU time — heavy load can cause spurious timeouts.

### `--error-style` flag

Replaces `--prominent-compile-errors` (which is gone). Options: `verbose`
(default), `minimal`, `verbose_clear`, `minimal_clear`. The `_clear`
variants clear the terminal on rebuild under `--watch`. Also reads
`ZIG_BUILD_ERROR_STYLE` env var.

### `--multiline-errors` flag

Options: `indent` (default), `newline`, `none`. Reads
`ZIG_BUILD_MULTILINE_ERRORS` env var.

### Temporary files API

- `RemoveDir` step **removed** (no replacement; it had no valid purpose).
- `Build.makeTempPath` **removed** (was used at configure-time, which is
  the wrong place).

`WriteFile` step gained:

- **tmp mode** — placed in `tmp/` rather than `o/`, caching skipped, ops
  always run in `make` phase, deleted on successful build completion.
  Helper: `Build.addTempFiles`.
- **mutate mode** — operations run against a temporary directory rather
  than a fresh one. Helper: `Build.addMutateFiles`.
- `Build.tmpPath` — shortcut for `addTempFiles` + `getDirectory`.

Migration from `b.makeTempPath()` + `addRemoveDirTree` → `b.addTempFiles`.

### `@cImport` deprecated

Moving to the build system instead. Soft deprecation — still works, now
backed by `arocc` instead of libclang.

```zig
// build.zig
const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
translate_c.linkSystemLibrary("glfw", .{});
translate_c.linkSystemLibrary("epoxy", .{});

const exe = b.addExecutable(.{
    // ...
    .root_module = b.createModule(.{
        // ...
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
        },
    }),
});
```

```zig
// In source
const c = @import("c");
```

---

## 26. Compiler / Linker / Fuzzer

### C Translation

`translate-c` is now based on **arocc** (Andrew Kelley's C compiler in
Zig) — the libclang-backed implementation has been dropped (-5,940 lines
of C++). Compiled lazily from source on first `@cImport`. Progress toward
"transition from a library dependency on LLVM to a process dependency on
Clang."

### LLVM backend

- **Experimental incremental compilation support.**
- 3-7% smaller LLVM bitcode.
- ~3% faster compilation in some cases.
- Error set types now lowered as enums — error names visible at runtime.
- Fixed debug info for unions with zero-bit payloads.
- Debug info now includes correct names for all types.
- Passing 2004/2010 (100%) of behavior tests vs. x86 backend.

### Reworked byval syntax lowering

The early "lower byval to reduce instructions" experiment was a failure
(array access perf, surprising aliasing, degenerate-case codegen). The
frontend now lowers expressions "byref" until the final load.

### Incremental compilation

- Significantly faster — avoids "over-analysis" in most cases.
- No longer triggers dependency-loop errors that don't occur in
  non-incremental builds.
- New ELF linker enabled by default for self-hosted ELF targets.
- LLVM backend now supports incremental — does **not** speed up "LLVM
  Emit Object" (LLVM's responsibility), but does speed up bitcode
  generation. Near-instant compile-error feedback even with LLVM.
- Still has known bugs; disabled by default. Opt in with
  `zig build -fincremental --watch`.

### x86 backend

- 11 bugs fixed, better constant memcpy codegen.
- More behavior tests passing than LLVM backend.
- Faster compilation, superior debug info, inferior machine code quality.
- **Default in Debug mode.**

### aarch64 backend

Still WIP, paused for I/O churn. Currently crashes on behavior tests.

### WebAssembly backend

Passing 1813/1970 (92%) of behavior tests vs. LLVM backend.

### New ELF linker

`-fnew-linker` flag, or `exe.use_new_linker = true`. Default with
`-fincremental` + ELF.

Performance data: building Zig itself + two single-line edits:

| Linker       | Initial | Edit 1 | Edit 2 |
| ------------ | ------- | ------ | ------ |
| Old linker   | 14s     | 194ms  | 191ms  |
| New linker   | 14s     | 65ms   | 64ms   |
| Skip linking | 14s     | 62ms   | 62ms   |

> The performance is fast enough that there is **no longer much benefit
> to exposing a `-Dno-bin` build step.** You might as well keep codegen
> and linking always enabled.

Not feature-complete vs. LLD or the old linker — produces no DWARF info.
Old linker + LLD remain available.

### Fuzzer

- **Smith** — replaces `[]const u8` parameter with `*std.testing.Smith`
  for value generation. Methods: `value`, `eos`, `bytes`, `slice`.
  Probability weighting via `[]const Smith.Weight`.
- **Multiprocess fuzzing** — `-j` flag.
- **Infinite mode** — switches between tests, prioritizes effective ones.
- **Crash dumps** — saved to file, reproducible via
  `std.testing.FuzzInputOptions.corpus` + `@embedFile`.
- An AST smith found 20 unique `zig fmt` bugs.

---

## 27. Toolchain: LLVM 21, libc updates

- **LLVM 21.1.0** — covers Clang, libc++, libc++abi, libunwind, libtsan.
  ⚠️ **Loop vectorization disabled** to work around an LLVM regression
  that miscompiles Zig itself. Pessimises codegen but avoids
  miscompilations. Will affect 0.16.x and 0.17.x; expected fix in 0.18.x.
- **musl 1.2.5** — many functions now provided by zig libc rather than
  copied musl source files. -331 musl C files distributed.
- **glibc 2.43** — available when cross-compiling.
- **Linux 6.19 headers**.
- **macOS 26.4 headers**.
- **MinGW-w64** — same commit, but -99 fewer C source files (zig libc
  takes over).
- **FreeBSD 15.0 libc** — available when cross-compiling.
- **WASI libc** — updated commit; counts up because of pthread shims.
- **zig libc** — total C source files distributed went from 2,270 to
  1,873 (-17%). Includes many math functions, `malloc` and friends.
- **OpenBSD 7.8+** cross-compilation supported.
- **macOS minimum**: 13.0. **Linux minimum**: 5.10. **Windows minimum**: 10.

### OS minimum versions

| OS            | Min  |
| ------------- | ---- |
| DragonFly BSD | 6.0  |
| FreeBSD       | 14.0 |
| Linux         | 5.10 |
| NetBSD        | 10.1 |
| OpenBSD       | 7.8  |
| macOS         | 13.0 |
| Windows       | 10   |

### Target shifts

- AArch64-/PowerPC-/s390x-Linux now natively tested in CI (thanks to OSUOSL
  + IBM hardware).
- `aarch64-maccatalyst` / `x86_64-maccatalyst` cross-compilation added.
- Initial `loongarch32-linux` (no libc).
- Basic support for Alpha, KVX, MicroBlaze, OpenRISC, PA-RISC, SuperH (C
  backend or external LLVM/Clang fork only).
- **Removed**: Solaris, AIX, z/OS. (illumos remains supported.)
- Stack-tracing improvements — almost all major targets now provide
  stack traces on crashes.
- Big-endian ARM emits BE8 object files for ARMv6+ (legacy BE32 dropped).

---

## 28. Gooey-specific takeaways

What we already absorbed (cross-reference with `zig-0.16-io-migration.md`):

- ✅ `std.Io` threaded through framework via `Cx`. `cx.io()` accessor.
- ✅ Platform dispatchers deleted. `Io.Queue(T)` + `cx.drainQueue` instead.
- ✅ `Io.Group` + cancel-group registry for entity/window lifecycle.
- ✅ `std.http.Client` + `Io` for image URL loading.
- ✅ `std.Io.Mutex` for atlases / text caches; render mutex stays as
  platform shim (CVDisplayLink thread has no `Io`).
- ✅ `std.Io.Timestamp.now(io, .awake)` everywhere; `time.zig` deleted.
- ✅ `std.testing.io` in tests.
- ✅ `init.minimal.args.vector` in benchmarks (replaces `std.os.argv`).
- ✅ `std.Io.Clock.real.now(io).toSeconds()` (replaces
  `std.time.timestamp()`).
- ✅ `std.Io.Writer.fixed(buf)` (replaces `std.io.fixedBufferStream`).
- ✅ `ArrayList(T) = .{}` → `.empty`.
- ✅ `File.{Reader,Writer}` byte-sink methods on `.interface`.

Things to be aware of going forward:

- **WASM**: deferred on 0.16.0 — `std.Io.Threaded` references
  `posix.system.getrandom` and `posix.IOV_MAX` eagerly, both `void` on
  `wasm32-freestanding`. **Upstream bug, not a Gooey bug.** WASM build
  steps removed from `build.zig` for the 0.1.0 tag. Watch for upstream
  fix gated on `native_os` or the `@TypeOf(...) != void` idiom.
- **`Io.Evented` for macOS** is still experimental; revisit later. Would
  give us native GCD integration through the `Io` interface (Phase 6 in
  the migration doc).
- **`@cImport` deprecation** — we don't currently use much C interop, but
  if/when we add some (e.g., direct CoreText calls), use `addTranslateC`
  from `build.zig` rather than `@cImport`.
- ✅ **`@Type` removal** — folded into PR 0 (audit-only, see
  [`cleanup-implementation-plan.md` PR 0](./cleanup-implementation-plan.md#pr-0--mechanical-016-sweep)).
  `grep -rn "@Type(" src/` returns 0 matches as of `main` @ `4d350e1`
  (v0.1.2); all 18 `@typeInfo` call sites already use the lower-case
  tag form. Per-module re-audits at the head of PR 4, PR 6, PR 8, PR 11
  if/when meta-programming is added.
- ✅ **Compile errors on returning local addresses** — folded into PR 0
  (audit-only). `zig build` against 0.16.0 surfaces no
  "address of local returned" diagnostics. Re-checked at the head of
  every subsequent PR.
- ✅ **Vectors no longer support runtime indexing** — folded into PR 0
  (audit-only). `grep -rn "@Vector" src/` returns 0 matches; no SIMD
  code in the codebase as of `main` @ `4d350e1`. PR 2 (rasterizer) and
  PR 10 (layout SIMD) re-audit if `@Vector` use is introduced.
- **Loop vectorization disabled (LLVM 21 regression)** — codegen may
  pessimise; affects 0.16.x and 0.17.x. Worth a perf re-baseline on hot
  paths (text shaping, atlas blits, layout traversal). Not actionable on
  our side, just a heads-up.
- ✅ **`heap.ArenaAllocator` is now lock-free thread-safe** — folded
  into PR 0 (audit-only). Only `src/layout/arena.zig` and
  `src/text/benchmarks.zig` use `std.heap.ArenaAllocator`; neither
  wraps it in a mutex, so no redundant wraps to remove.
- **`Thread.Pool` is gone** — we never used it directly, but any third-
  party code in the dependency tree using it will need migration to
  `Io.Group`.
- **Process / env vars / argv non-global** — we already absorbed this in
  the bench Reporter API (explicit `argv` parameter). Any future code
  that wants env vars must take `*const process.Environ.Map` or grab
  from `init.environ_map` in `main`.
- **`fs.path.relative` is now pure** — if we ever do path manipulation,
  we need to thread `cwd_path` and `environ_map` through.
- **Atomic file API change** — if/when we add settings persistence or
  document-save, use `createFileAtomic` + `replace(io)` rather than the
  old `atomicFile` + `renameIntoPlace`.
- **`File.Stat.atime` is now `?i128`** — any file-time logic must handle
  the optional. Mostly relevant for the watcher / hot-reload paths.
- **`std.testing.Smith`** — opens up real fuzzing of layout, text shaping,
  and accessibility tree code. Worth filing a follow-up to add fuzz
  targets for the layout engine and text shaper.
- **`zig build --fork=`** — useful local-dev flow if we ever vendor a
  package fork (e.g., a tweaked `arocc` or a freetype binding).

---

## References

- [Zig 0.16.0 Release Notes](https://ziglang.org/download/0.16.0/release-notes.html)
- [`zig-0.16-io-migration.md`](./zig-0.16-io-migration.md) — Gooey's
  migration plan and current state
- [std.Io PR #25592](https://github.com/ziglang/zig/pull/25592)
- [std.io.Writer rewrite PR #24329](https://github.com/ziglang/zig/pull/24329)
- [`@Type` proposal #10710](https://github.com/ziglang/zig/issues/10710)
- [Pointers in packed types proposal #24657](https://github.com/ziglang/zig/issues/24657)
- [Implicit backing types in extern proposal #24714](https://github.com/ziglang/zig/issues/24714)
- [`fs.path` Windows fixes #25993](https://github.com/ziglang/zig/issues/25993)
- [CLAUDE.md](../CLAUDE.md) — Gooey engineering principles
