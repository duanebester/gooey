//! The lifecycle allocation guard (contract rule 2, CLAUDE.md §2).
//!
//! Every allocation the core makes goes through `LifecycleGuard.allocator()`.
//! While the lifecycle is `initializing` or `deinitializing`, calls pass
//! through to the backing allocator. While it is `running`, any call panics
//! with what was requested, so an allocation after the initialization
//! boundary fails the first test or run that reaches it. Storage claimed
//! from reservations (record frames, pools, the text scratch) is not an
//! allocation and does not pass through the guard.
//!
//! The guard runs in every build mode. It costs one branch per allocation,
//! and only initialization and teardown allocate.

const std = @import("std");

const assert = std.debug.assert;

pub const Lifecycle = enum { initializing, running, deinitializing };

pub const LifecycleGuard = struct {
    backing: std.mem.Allocator,
    lifecycle: Lifecycle,
    /// Bytes requested while initializing, for the memory report.
    init_bytes: u64,
    init_allocations: u32,

    pub fn init(backing: std.mem.Allocator) LifecycleGuard {
        return .{
            .backing = backing,
            .lifecycle = .initializing,
            .init_bytes = 0,
            .init_allocations = 0,
        };
    }

    pub fn allocator(self: *LifecycleGuard) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Cross the initialization boundary: no allocation from here on.
    pub fn enterRunning(self: *LifecycleGuard) void {
        assert(self.lifecycle == .initializing);
        self.lifecycle = .running;
    }

    /// Begin teardown: frees, and only frees, are expected from here on.
    pub fn enterDeinitializing(self: *LifecycleGuard) void {
        assert(self.lifecycle != .deinitializing);
        self.lifecycle = .deinitializing;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn fromContext(context: *anyopaque) *LifecycleGuard {
        return @ptrCast(@alignCast(context));
    }

    fn rejectRunning(self: *const LifecycleGuard, operation: []const u8, len: usize) void {
        if (self.lifecycle != .running) return;
        std.debug.panic("allocation after initialization: {s} of {d} bytes while the " ++
            "lifecycle is running (CLAUDE.md §2). Reserve the storage at init.", .{
            operation,
            len,
        });
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self = fromContext(context);
        self.rejectRunning("alloc", len);
        if (self.lifecycle == .initializing) {
            self.init_bytes += len;
            self.init_allocations += 1;
        }
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self = fromContext(context);
        self.rejectRunning("resize", new_len);
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self = fromContext(context);
        self.rejectRunning("remap", new_len);
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = fromContext(context);
        self.rejectRunning("free", memory.len);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "the guard passes allocations through only outside running" {
    // Goal: initializing and deinitializing allocate normally and running is
    // closed. Method: allocate in each phase that permits it; the running
    // phase's panic is exercised by the core's tick tests, which would abort.
    var guard = LifecycleGuard.init(std.testing.allocator);
    const gpa = guard.allocator();
    const bytes = try gpa.alloc(u8, 32);
    try std.testing.expectEqual(@as(u64, 32), guard.init_bytes);
    guard.enterRunning();
    try std.testing.expectEqual(Lifecycle.running, guard.lifecycle);
    guard.enterDeinitializing();
    gpa.free(bytes);
    try std.testing.expectEqual(@as(u32, 1), guard.init_allocations);
}
